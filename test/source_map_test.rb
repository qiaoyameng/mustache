require_relative 'helper'

class SourceMapTest < Minitest::Test
  # A view whose partials live in memory.
  class MailView < Mustache
    PARTIALS = {
      'header' => "H1 {{title}}\nH2\n",
      'footer' => "F {{& x}}\n",
      'outer'  => "O[{{> inner}}]",
      'inner'  => "I{{v}}",
    }

    def partial(name)
      PARTIALS.fetch(name.to_s)
    end
  end

  def render_with_map(template, ctx = {})
    view = MailView.new
    view.template = template
    view.render_with_map(ctx)
  end

  def render(template, ctx = {})
    view = MailView.new
    view.template = template
    view.render(ctx)
  end

  def assert_full_coverage(output, map)
    if map.empty?
      assert_equal "", output
      return
    end

    assert_equal 0, map.first[:range].begin
    assert_equal output.bytesize, map.last[:range].end
    map.each_cons(2) do |a, b|
      assert_equal a[:range].end, b[:range].begin, "segments must be contiguous"
    end
    assert_equal output, map.map { |s| output.byteslice(s[:range]) }.join
  end

  def assert_byte_identical(template, ctx = {})
    output, map = render_with_map(template, ctx)
    assert_equal render(template, ctx), output
    assert_full_coverage(output, map)
    [output, map]
  end

  def test_byte_identical_for_many_templates
    ctx = {
      :name => "<b>&\"'",
      :chinese => "中文内容",
      :items => [{ :v => 1 }, { :v => 2 }],
      :strings => %w[a b],
      :ok => true,
      :nothing => false,
      :hash => { :a => { :b => "dot" } },
      :lam => lambda { |raw| "L<#{raw}>" },
      :val_lam => lambda { "[[{{chinese}}]]" },
    }

    templates = [
      "",
      "plain text",
      "中文静态文本",
      "Hi {{name}}!",
      "{{chinese}}",
      "{{& name}}",
      "{{{name}}}",
      "{{#items}}{{v}},{{/items}}",
      "{{#strings}}{{.}}{{/strings}}",
      "{{#ok}}yes {{name}}{{/ok}}",
      "{{#nothing}}no{{/nothing}}",
      "{{^nothing}}inverted {{chinese}}{{/nothing}}",
      "{{hash.a.b}}",
      "{{! comment}}after",
      "{{=<% %>=}}<%name%>",
      "{{#lam}}raw {{chinese}}{{/lam}}",
      "{{val_lam}}",
      "{{& val_lam}}",
      "a\n  {{> header}}b {{> footer}}c\n",
      "{{#items}}({{> outer}}){{/items}}",
      "  {{> header}}",
    ]

    templates.each do |template|
      assert_byte_identical(template, ctx)
    end
  end

  def test_kinds_and_escaping
    output, map = assert_byte_identical("Hi {{name}}! {{& name}}", :name => "&<")

    assert_equal "Hi &amp;&lt;! &<", output
    assert_equal [:static, :etag, :static, :utag], map.map { |s| s[:kind] }

    # The whole escaped run (multiple entity characters from a single
    # variable) points at the one tag.
    etag = map[1]
    assert_equal "&amp;&lt;", output.byteslice(etag[:range])
    assert_equal 1, etag[:source][:line]
    assert_equal :template, etag[:source][:type]

    utag = map[3]
    assert_equal "&<", output.byteslice(utag[:range])
  end

  def test_chinese_positions_and_slicing
    output, map = assert_byte_identical("你好 {{name}}\n第二行", :name => "世界")

    static = map.first
    assert_equal :static, static[:kind]
    assert_equal "你好 ", output.byteslice(static[:range])
    assert_equal 1, static[:source][:line]
    assert_equal 0, static[:source][:column]

    etag = map[1]
    assert_equal "世界", output.byteslice(etag[:range])
    assert_equal 1, etag[:source][:line]
    # Columns are character-based, even with multibyte text.
    assert_equal 8, etag[:source][:column]

    last = map.last
    assert_equal "\n第二行", output.byteslice(last[:range])
    assert_equal 1, last[:source][:line]
  end

  def test_partial_identity_and_call_chain
    output, map = assert_byte_identical("{{> outer}}", :v => "x")

    assert_equal "O[Ix]", output

    inner = map.find { |s| s[:source][:name] == "inner" }
    assert_equal :partial, inner[:source][:type]
    assert_equal ["outer", "inner"], inner[:call_chain].map { |c| c[:name] }

    outer = map.find { |s| s[:source][:name] == "outer" }
    assert_equal ["outer"], outer[:call_chain].map { |c| c[:name] }
  end

  def test_standalone_indentation_is_marked
    output, map = assert_byte_identical("T\n  {{> header}}\nend\n", :title => "t")

    assert_equal "T\n  H1 t\n  H2\nend\n", output

    indentations = map.select { |s| s[:kind] == :indentation }
    assert_equal 2, indentations.size
    indentations.each do |seg|
      assert_equal "  ", output.byteslice(seg[:range])
      # Indentation belongs to the partial tag in the main template.
      assert_equal :template, seg[:source][:type]
      assert_equal [], seg[:call_chain]
    end

    # The partial's own bytes use the partial's identity and chain.
    h1 = map.find { |s| s[:kind] == :static && output.byteslice(s[:range]) == "H1 " }
    assert_equal "header", h1[:source][:name]
    assert_equal ["header"], h1[:call_chain].map { |c| c[:name] }
  end

  def test_lambda_gets_dynamic_source
    calls = 0
    lam = lambda { |raw| calls += 1; "L<#{raw}>" }
    output, map = render_with_map("{{#lam}}raw {{x}}{{/lam}}", :lam => lam, :x => "X")

    assert_equal "L<raw X>", output
    assert_equal 1, calls, "lambda must be called exactly once"
    assert_equal render("{{#lam}}raw {{x}}{{/lam}}", :lam => lam, :x => "X"), output
    assert_full_coverage(output, map)

    map.each do |seg|
      assert_equal :lambda, seg[:source][:type]
      assert_equal "lam", seg[:source][:name]
    end
  end

  def test_lambda_does_not_masquerade_as_file_lines
    lam = lambda { |raw| "generated {{x}}" }
    _, map = render_with_map("{{#lam}}ignored{{/lam}}", :lam => lam, :x => "y")

    map.each do |seg|
      refute_equal :template, seg[:source][:type],
        "dynamic content must not claim template file positions"
    end
  end

  def test_etag_lambda_is_single_dynamic_segment
    lam = lambda { "<{{x}}>" }
    output, map = assert_byte_identical("{{lam}}", :lam => lam, :x => "x")

    assert_equal "&lt;x&gt;", output
    assert_equal 1, map.size
    assert_equal :etag, map.first[:kind]
    assert_equal :lambda, map.first[:source][:type]
  end

  def test_getters_are_not_called_twice
    klass = Class.new(Mustache) do
      attr_reader :counts

      def initialize(*)
        @counts = Hash.new(0)
        super
      end

      def name
        @counts[:name] += 1
        "N"
      end

      def items
        @counts[:items] += 1
        [1, 2]
      end
    end

    mapped = klass.new
    mapped.template = "{{name}} {{#items}}{{name}}{{/items}}"
    output, _ = mapped.render_with_map

    assert_equal "N NN", output

    plain = klass.new
    plain.template = "{{name}} {{#items}}{{name}}{{/items}}"
    assert_equal output, plain.render

    # Source tracking must not fetch anything more than render does.
    assert_equal plain.counts, mapped.counts
  end

  def test_empty_output
    assert_equal ["", []], Mustache.render_with_map("", {})
    assert_equal ["", []], Mustache.render_with_map("{{#f}}x{{/f}}", :f => false)
    assert_equal ["", []], Mustache.render_with_map("{{! just a comment}}", {})
  end

  def test_values_are_not_recorded
    _, map = render_with_map("{{name}}", :name => "secret")

    map.each do |seg|
      assert_equal [:range, :kind, :source, :call_chain], seg.keys
      assert_equal [:type, :name, :line, :column], seg[:source].keys
    end
  end

  def test_adjacent_same_source_segments_are_merged
    output, map = assert_byte_identical("{{#items}}-{{/items}}", :items => [1, 2, 3])

    assert_equal "---", output
    assert_equal 1, map.size
    assert_equal 0...3, map.first[:range]
  end

  def test_template_render_with_map
    template = Mustache::Template.new("Hi {{name}}!")
    view = Mustache.new
    view[:name] = "there"

    output, map = template.render_with_map(view.context)

    assert_equal "Hi there!", output
    assert_equal template.render(view.context), output
    assert_full_coverage(output, map)
  end

  def test_file_backed_template_identity
    klass = Class.new(Mustache)
    klass.template_path = File.dirname(__FILE__) + "/fixtures"
    klass.template_name = "inner_partial"

    output, map = klass.render_with_map(:title => "T")

    assert_equal klass.render(:title => "T"), output
    source = map.first[:source]
    assert_equal :template, source[:type]
    assert source[:name].end_with?("inner_partial.mustache")
  end

  def test_class_level_render_with_map
    output, map = Mustache.render_with_map("Hi {{thing}}!", :thing => :world)

    assert_equal "Hi world!", output
    assert_full_coverage(output, map)
    assert_equal "(inline)", map.first[:source][:name]
  end
end
