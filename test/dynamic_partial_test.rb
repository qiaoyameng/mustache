require_relative 'helper'

class DynamicPartialTest < Minitest::Test
  def build_view(mapping, template, options = {})
    view = Mustache.new(options.merge(:dynamic_partials => mapping))
    view.template = template
    view
  end

  def test_selects_partial_by_name_from_data
    mapping = {
      'greeting' => 'Hello {{name}}!',
      'farewell' => 'Bye {{name}}!',
    }
    view = build_view(mapping, '{{>*which}}')

    assert_equal 'Hello Alice!', view.render(:which => 'greeting', :name => 'Alice')
    assert_equal 'Bye Alice!', view.render(:which => 'farewell', :name => 'Alice')
  end

  def test_name_supports_dotted_lookup
    view = build_view({'frag' => 'dot'}, '{{>*config.fragment}}')

    assert_equal 'dot', view.render(:config => {:fragment => 'frag'})
  end

  def test_alternating_partials_with_same_local_variable_names
    mapping = {
      'header' => '<h1>{{title}}</h1>',
      'footer' => '<footer>{{title}}</footer>',
    }
    view = build_view(mapping, '{{>*fragment}}')

    # The template compiles on the first render; later renders must
    # not reuse the fragment selected by an earlier render.
    assert_equal '<h1>First</h1>', view.render(:fragment => 'header', :title => 'First')
    assert_equal '<footer>Second</footer>', view.render(:fragment => 'footer', :title => 'Second')
    assert_equal '<h1>Third</h1>', view.render(:fragment => 'header', :title => 'Third')
    assert_equal '<footer>Fourth</footer>', view.render(:fragment => 'footer', :title => 'Fourth')
  end

  def test_unregistered_name_raises
    view = build_view({'header' => 'hi'}, '{{>*fragment}}')

    error = assert_raises(Mustache::DynamicPartialNotRegistered) do
      view.render(:fragment => 'secret')
    end
    assert_match(/secret/, error.message)
  end

  def test_dynamic_partial_does_not_fall_back_to_view_partial
    klass = Class.new(Mustache) do
      def partial(name)
        'FROM_VIEW_PARTIAL'
      end
    end
    view = klass.new(:dynamic_partials => {'ok' => 'OK'})
    view.template = '{{>*which}}'

    assert_equal 'OK', view.render(:which => 'ok')
    assert_raises(Mustache::DynamicPartialNotRegistered) do
      view.render(:which => 'other')
    end
  end

  def test_missing_name_variable_raises
    view = build_view({'header' => 'hi'}, '{{>*fragment}}')

    assert_raises(Mustache::DynamicPartialNameMissing) { view.render }
  end

  def test_empty_name_raises
    view = build_view({'header' => 'hi'}, '{{>*fragment}}')

    assert_raises(Mustache::DynamicPartialNameInvalid) do
      view.render(:fragment => '')
    end
  end

  def test_non_string_name_raises
    view = build_view({'header' => 'hi'}, '{{>*fragment}}')

    assert_raises(Mustache::DynamicPartialNameInvalid) do
      view.render(:fragment => :header)
    end
    assert_raises(Mustache::DynamicPartialNameInvalid) do
      view.render(:fragment => 42)
    end
  end

  def test_name_is_not_coerced
    called = false
    impostor = Object.new
    impostor.define_singleton_method(:to_str) { called = true; 'header' }
    impostor.define_singleton_method(:to_s) { called = true; 'header' }

    view = build_view({'header' => 'hi'}, '{{>*fragment}}')

    assert_raises(Mustache::DynamicPartialNameInvalid) do
      view.render(:fragment => impostor)
    end
    assert_equal false, called
  end

  def test_syntax_requires_opt_in
    view = Mustache.new
    view.template = '{{>*fragment}}'

    assert_raises(Mustache::Parser::SyntaxError) do
      view.render(:fragment => 'header')
    end
  end

  def test_empty_dynamic_name_is_a_syntax_error
    view = build_view({'header' => 'hi'}, '{{>*}}')

    assert_raises(Mustache::Parser::SyntaxError) { view.render }
  end

  def test_rejected_with_inline_partials_at_compile_time
    view = Mustache.new(:inline_partials_at_compile_time => true,
                        :dynamic_partials => {'frag' => 'x'})
    view.template = '{{>*frag}}'

    error = assert_raises(Mustache::Parser::SyntaxError) { view.render(:frag => 'frag') }
    assert_match(/inline_partials_at_compile_time/, error.message)
  end

  def test_standalone_indentation_matches_static_partials
    mapping = {'item' => "one\ntwo\n"}
    template = "list:\n  {{>*which}}\ndone\n"
    view = build_view(mapping, template)

    assert_equal "list:\n  one\n  two\ndone\n", view.render(:which => 'item')
  end

  def test_works_with_changed_delimiters
    view = build_view({'item' => 'OK'}, '{{=<% %>=}}<%>*which%>')

    assert_equal 'OK', view.render(:which => 'item')
  end

  def test_nested_dynamic_partials
    mapping = {
      'outer' => 'outer[{{>*inner}}]',
      'inner' => 'inner({{label}})',
    }
    view = build_view(mapping, '{{>*a}}')

    assert_equal 'outer[inner(x)]', view.render(:a => 'outer', :inner => 'inner', :label => 'x')
  end

  def test_recursive_dynamic_partial_hits_depth_limit
    mapping = {'loop' => 'x{{>*next}}'}
    view = build_view(mapping, '{{>*next}}')

    assert_raises(Mustache::DynamicPartialRecursionError) do
      view.render(:next => 'loop')
    end
  end

  def test_dynamic_partials_class_setting
    klass = Class.new(Mustache)
    klass.dynamic_partials = {'frag' => 'class-level {{who}}'}
    view = klass.new
    view.template = '{{>*which}}'

    assert_equal 'class-level A', view.render(:which => 'frag', :who => 'A')
  end

  def test_dynamic_partials_with_class_level_template
    klass = Class.new(Mustache)
    klass.dynamic_partials = {'frag' => 'class-template'}
    klass.template = '{{>*which}}'

    assert_equal 'class-template', klass.render(:which => 'frag')
  end

  def test_mapping_with_symbol_keys
    view = build_view({:frag => 'sym'}, '{{>*which}}')

    assert_equal 'sym', view.render(:which => 'frag')
  end

  def test_missing_variable_with_raise_on_context_miss
    view = build_view({'header' => 'hi'}, '{{>*fragment}}')
    view.raise_on_context_miss = true

    assert_raises(Mustache::ContextMiss) { view.render }
  end
end
