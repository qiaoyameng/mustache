# encoding: utf-8
require_relative 'helper'

class SourceMapTest < Minitest::Test
  SourceMapPartials = Class.new(Mustache) do
    PARTIALS = {
      :outer => "O1\n{{> inner}}\nO2\n",
      :inner => "I1 {{x}}\nI2"
    }

    def partial(name)
      PARTIALS.fetch(name.to_sym)
    end
  end

  def assert_coverage(output, segments)
    position = 0
    segments.each do |segment|
      assert_equal position, segment.range.begin, "gap or overlap before #{segment.inspect}"
      position = segment.range.end
    end
    assert_equal output.bytesize, position, "segments must cover the whole output"
  end

  def test_returns_same_string_as_render
    view = Mustache.new
    context = {
      :name => "世界<&",
      :items => [{ :n => "甲" }, { :n => "乙" }],
      :words => ["a", "b"],
      :ok => true,
      :nothing => false,
      :raw => "<b>x</b>"
    }
    templates = [
      "Hello {{name}}!",
      "你好，{{name}}！\n多行 {{raw}} 文本",
      "{{#items}}{{n}};{{/items}}",
      "{{#words}}{{.}}{{/words}}",
      "{{#ok}}yes {{name}}{{/ok}}{{^nothing}}none{{/nothing}}",
      "{{{raw}}} {{&raw}} {{raw}}",
      "{{=<% %>=}}<%name%>",
      "  {{name}}  \n\t{{raw}}\n",
      ""
    ]

    templates.each do |template|
      plain = view.render(template, context)
      mapped, segments = view.render_with_map(template, context)
      assert_equal plain, mapped, "output mismatch for #{template.inspect}"
      assert_equal plain.bytes, mapped.bytes
      assert_coverage mapped, segments
    end
  end

  def test_chinese_utf8_byte_ranges
    view = Mustache.new
    template = "你好，{{name}}！"
    plain = view.render(template, :name => "世界")
    mapped, segments = view.render_with_map(template, :name => "世界")

    assert_equal plain, mapped
    assert_equal "你好，世界！", mapped
    assert_coverage mapped, segments

    etag = segments.find { |s| s.kind == :etag }
    assert_equal "世界", mapped.byteslice(etag.range)
    assert_equal "你好，".bytesize, etag.offset
    assert_equal [1, "你好，".bytesize], etag.source.line_and_column(etag.offset)

    first = segments.first
    assert_equal :static, first.kind
    assert_equal "你好，", mapped.byteslice(first.range)
    assert_equal "你好，", first.source.text.byteslice(first.offset, first.length)
  end

  def test_escaped_entities_stay_a_single_tag_segment
    view = Mustache.new
    template = "<p>{{content}}</p>"
    context = { :content => "a<b>&\"'" }
    plain = view.render(template, context)
    mapped, segments = view.render_with_map(template, context)

    assert_equal plain, mapped
    assert_equal "<p>a&lt;b&gt;&amp;&quot;&#39;</p>", mapped
    assert_coverage mapped, segments

    etags = segments.select { |s| s.kind == :etag }
    assert_equal 1, etags.size
    assert_equal "a&lt;b&gt;&amp;&quot;&#39;", mapped.byteslice(etags[0].range)
    assert_equal "(inline template)", etags[0].source.name
    refute etags[0].source.dynamic?
    assert_equal template.index("{{content}}"), etags[0].offset
  end

  def test_kinds_for_static_etag_and_utag
    view = Mustache.new
    mapped, segments = view.render_with_map("a {{e}} {{{u}}} {{&v}}", :e => "1", :u => "2", :v => "3")

    assert_equal "a 1 2 3", mapped
    assert_coverage mapped, segments
    assert_equal [:static, :etag, :static, :utag, :static, :utag], segments.map(&:kind)
    assert_equal ["a ", "1", " ", "2", " ", "3"], segments.map { |s| mapped.byteslice(s.range) }
  end

  def test_nested_partials_have_own_source_and_call_chain
    view = SourceMapPartials.new
    template = "A\n  {{> outer}}\nZ"
    context = { :x => "x" }
    plain = view.render(template, context)
    mapped, segments = view.render_with_map(template, context)

    assert_equal plain, mapped
    assert_equal "A\n  O1\n  I1 x\n  I2  O2\nZ", mapped
    assert_coverage mapped, segments

    inner = segments.select { |s| s.source.name == "inner" }
    refute_empty inner
    inner.each { |s| assert_equal [:outer, :inner], s.source.call_chain }

    outer = segments.select { |s| s.source.name == "outer" && s.kind == :static }
    refute_empty outer
    outer.each { |s| assert_equal [:outer], s.source.call_chain }

    # Static slices match the original (un-indented) partial sources.
    segments.each do |segment|
      next unless segment.kind == :static
      slice = mapped.byteslice(segment.range)
      assert_equal slice, segment.source.text.byteslice(segment.offset, slice.bytesize)
    end
  end

  def test_standalone_indentation_is_marked_and_points_at_partial_tag
    view = SourceMapPartials.new
    template = "A\n  {{> outer}}\nZ"
    mapped, segments = view.render_with_map(template, :x => "x")

    indentations = segments.select { |s| s.kind == :indentation }
    refute_empty indentations
    indentations.each { |s| assert_equal "  ", mapped.byteslice(s.range) }

    # Indentation of outer's lines points at the {{> outer}} tag in the
    # main template; indentation of inner's lines points at the
    # {{> inner}} tag inside outer.
    main_indents = indentations.select { |s| s.source.name == "(inline template)" }
    refute_empty main_indents
    main_indents.each { |s| assert_equal template.index("{{> outer}}"), s.offset }

    outer_indents = indentations.select { |s| s.source.name == "outer" }
    refute_empty outer_indents
    outer_indents.each { |s| assert_equal "outer", s.source.name }
    outer_indents.each { |s| assert_equal "O1\n{{> inner}}\nO2\n".index("{{> inner}}"), s.offset }
  end

  def test_section_lambda_gets_independent_dynamic_source
    view = Mustache.new
    calls = 0
    context = {
      :wrap => lambda { |raw| calls += 1; "<b>#{raw}</b>" },
      :item => "项"
    }
    template = "{{#wrap}}{{item}}{{/wrap}}"
    plain = view.render(template, context)
    before = calls
    mapped, segments = view.render_with_map(template, context)

    assert_equal plain, mapped
    assert_equal "<b>项</b>", mapped
    assert_equal before + 1, calls, "lambda must be called exactly once"
    assert_coverage mapped, segments

    assert segments.all? { |s| s.source.dynamic? }, "lambda output must not claim template file lines"
    assert segments.all? { |s| s.source.name == "lambda:wrap" }

    etag = segments.find { |s| s.kind == :etag }
    assert_equal "项", mapped.byteslice(etag.range)
    assert etag.source.dynamic?
    assert_equal "<b>{{item}}</b>".index("{{item}}"), etag.offset
  end

  def test_unescaped_lambda_output_uses_dynamic_source
    view = Mustache.new
    calls = 0
    context = { :lam => lambda { calls += 1; "{{x}}!" }, :x => "动态" }
    plain = view.render("{{{lam}}}", context)
    before = calls
    mapped, segments = view.render_with_map("{{{lam}}}", context)

    assert_equal plain, mapped
    assert_equal "动态!", mapped
    assert_equal before + 1, calls
    assert segments.all? { |s| s.source.dynamic? }
    assert_equal [:etag, :static], segments.map(&:kind)
  end

  def test_escaped_lambda_result_maps_to_the_tag
    view = Mustache.new
    context = { :lam => lambda { "a<b" } }
    plain = view.render("{{lam}}", context)
    mapped, segments = view.render_with_map("{{lam}}", context)

    assert_equal plain, mapped
    assert_equal "a&lt;b", mapped
    assert_equal 1, segments.size
    assert_equal :etag, segments[0].kind
    refute segments[0].source.dynamic?
  end

  def test_getters_are_not_called_twice
    view = Class.new(Mustache) do
      attr_reader :name_calls

      def name
        @name_calls = (@name_calls || 0) + 1
        "value"
      end
    end.new

    mapped, segments = view.render_with_map("{{name}}")
    assert_equal "value", mapped
    assert_equal 1, view.name_calls
  end

  def test_values_are_not_recorded_by_default
    view = Mustache.new
    _, segments = view.render_with_map("{{secret}}", :secret => "shh")
    assert segments.all? { |s| s.value.nil? }

    _, segments = view.render_with_map("{{secret}}", { :secret => "shh" }, :record_values => true)
    etag = segments.find { |s| s.kind == :etag }
    assert_equal "shh", etag.value
  end

  def test_empty_output
    view = Mustache.new

    mapped, segments = view.render_with_map("")
    assert_equal "", mapped
    assert_equal [], segments

    mapped, segments = view.render_with_map("{{missing}}", {})
    assert_equal view.render("{{missing}}", {}), mapped
    assert_equal "", mapped
    assert_equal [], segments
  end

  def test_class_method_render_with_map
    mapped, segments = Mustache.render_with_map("Hi {{thing}}!", :thing => "world")
    assert_equal "Hi world!", mapped
    assert_equal Mustache.render("Hi {{thing}}!", :thing => "world"), mapped
    assert_coverage mapped, segments
  end
end
