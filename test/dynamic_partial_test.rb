require_relative 'helper'

class DynamicPartialTest < Minitest::Test
  def partials
    {
      'greeting' => 'Hello, {{name}}!',
      'goodbye'  => 'Goodbye, {{name}}!'
    }
  end

  def view(template = '{{>*message}}', options = {})
    view = Mustache.new({:dynamic_partials => partials}.merge(options))
    view.template = template
    view
  end

  def test_selects_registered_partial_based_on_data
    assert_equal 'Hello, Alice!', view.render(:message => 'greeting', :name => 'Alice')
    assert_equal 'Goodbye, Bob!', view.render(:message => 'goodbye', :name => 'Bob')
  end

  def test_alternating_partials_with_same_local_variable_names
    view = view()

    # The first render compiles the template; later renders reuse the
    # compiled version. Each render must re-resolve the selected
    # partial instead of reusing the previously selected fragment.
    assert_equal 'Hello, Alice!', view.render(:message => 'greeting', :name => 'Alice')
    assert_equal 'Goodbye, Bob!', view.render(:message => 'goodbye', :name => 'Bob')
    assert_equal 'Hello, Carol!', view.render(:message => 'greeting', :name => 'Carol')
  end

  def test_unregistered_name_is_rejected
    error = assert_raises(Mustache::DynamicPartialNameNotRegistered) do
      view.render(:message => '../secret')
    end
    assert_match(/\.\.\/secret/, error.message)
  end

  def test_data_cannot_supply_template_source
    assert_raises(Mustache::DynamicPartialNameNotRegistered) do
      view.render(:message => '{{name}}')
    end
  end

  def test_missing_variable_raises
    error = assert_raises(Mustache::DynamicPartialNameMissing) do
      view.render(:name => 'Alice')
    end
    assert_match(/message/, error.message)
  end

  def test_missing_variable_raises_with_raise_on_context_miss
    view = view()
    view.raise_on_context_miss = true

    assert_raises(Mustache::DynamicPartialNameMissing) do
      view.render(:name => 'Alice')
    end
  end

  def test_empty_name_raises
    assert_raises(Mustache::DynamicPartialNameEmpty) do
      view.render(:message => '')
    end
  end

  def test_non_string_name_is_not_converted
    assert_raises(Mustache::DynamicPartialNameInvalid) do
      view.render(:message => :greeting)
    end
  end

  def test_proc_name_is_never_called
    called = false
    spy = proc { called = true; 'greeting' }

    assert_raises(Mustache::DynamicPartialNameInvalid) do
      view.render(:message => spy)
    end
    refute called
  end

  def test_dotted_lookup
    view = view('{{>*message.kind}}')
    assert_equal 'Hello, Alice!',
      view.render(:message => {:kind => 'greeting'}, :name => 'Alice')
  end

  def test_dotted_lookup_missing_intermediate
    assert_raises(Mustache::DynamicPartialNameMissing) do
      view('{{>*message.kind}}').render(:message => {}, :name => 'Alice')
    end
  end

  def test_standalone_indentation_matches_static_partials
    template = "{{#items}}\n  {{>*which}}\n{{/items}}"
    items = [
      {:which => 'line', :name => 'a'},
      {:which => 'line', :name => 'b'}
    ]

    dynamic = Mustache.new(:dynamic_partials => {'line' => "- {{name}}\n"})
    dynamic.template = template

    static = Mustache.new
    def static.partial(name) "- {{name}}\n" end
    static.template = "{{#items}}\n  {{>line}}\n{{/items}}"

    assert_equal "  - a\n  - b\n", dynamic.render(:items => items)
    assert_equal static.render(:items => items), dynamic.render(:items => items)
  end

  def test_custom_delimiters
    view = view('{{=<% %>=}}<%>*message%>')
    assert_equal 'Hello, Alice!', view.render(:message => 'greeting', :name => 'Alice')
  end

  def test_nested_dynamic_partials
    view = Mustache.new(:dynamic_partials => {
      'outer' => 'A{{>*inner}}Z',
      'inner' => '[{{name}}]'
    })
    view.template = '{{>*which}}'

    assert_equal 'A[x]Z',
      view.render(:which => 'outer', :inner => 'inner', :name => 'x')
  end

  def test_finite_recursion
    view = Mustache.new(:dynamic_partials => {
      'node' => '{{value}}{{#child}}{{>*next}}{{/child}}'
    })
    view.template = '{{>*which}}'

    data = {
      :which => 'node', :next => 'node', :value => '1',
      :child => {:value => '2', :child => {:value => '3', :child => nil}}
    }
    assert_equal '123', view.render(data)
  end

  def test_recursion_depth_limit
    view = Mustache.new(:dynamic_partials => {'loop' => 'x{{>*next}}'})
    view.template = '{{>*which}}'

    assert_raises(Mustache::DynamicPartialRecursionError) do
      view.render(:which => 'loop', :next => 'loop')
    end
  end

  def test_recursion_depth_limit_is_configurable
    view = Mustache.new(
      :dynamic_partials => {'loop' => 'x{{>*next}}'},
      :dynamic_partial_max_depth => 3
    )
    view.template = '{{>*which}}'

    error = assert_raises(Mustache::DynamicPartialRecursionError) do
      view.render(:which => 'loop', :next => 'loop')
    end
    assert_match(/3 levels/, error.message)
  end

  def test_dynamic_syntax_requires_opt_in
    view = Mustache.new
    view.template = '{{>*message}}'

    error = assert_raises(Mustache::Parser::SyntaxError) do
      view.render(:message => 'greeting')
    end
    assert_match(/not enabled/, error.message)
  end

  def test_inline_partials_at_compile_time_rejects_dynamic_names
    view = Mustache.new(
      :inline_partials_at_compile_time => true,
      :dynamic_partials => partials
    )
    view.template = '{{>*message}}'

    error = assert_raises(Mustache::Parser::SyntaxError) do
      view.render(:message => 'greeting')
    end
    assert_match(/inline_partials_at_compile_time/, error.message)
  end

  def test_class_level_setting
    klass = Class.new(Mustache)
    klass.dynamic_partials = partials
    klass.template = '{{>*message}}'

    assert_equal 'Hello, Alice!', klass.render(:message => 'greeting', :name => 'Alice')
  end
end
