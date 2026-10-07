require 'mustache/context_miss'
require 'mustache/dynamic_partial'

class Mustache

  # A Context represents the context which a Mustache template is
  # executed within. All Mustache tags reference keys in the Context.
  #
  class Context

    # Default maximum nesting depth for dynamic partials. Can be
    # overridden with the `dynamic_partial_max_depth` setting.
    MAX_DYNAMIC_PARTIAL_DEPTH = 32

    # Initializes a Mustache::Context.
    #
    # @param [Mustache] mustache A Mustache instance.
    #
    def initialize(mustache)
      @stack = [mustache]
      @partial_template_cache = {}
      @dynamic_partial_template_cache = {}
      @dynamic_partial_depth = 0
    end

    # A {{>partial}} tag translates into a call to the context's
    # `partial` method, which would be this sucker right here.
    #
    # If the Mustache view handling the rendering (e.g. the view
    # representing your profile page or some other template) responds
    # to `partial`, we call it and render the result.
    #
    def partial(name, indentation = '')
      # Look for the first Mustache in the stack.
      mustache = mustache_in_stack

      # Indent the partial template by the given indentation.
      part = mustache.partial(name).to_s.gsub(/^/, indentation)

      # Get a template object for the partial and render the result.
      template_for_partial(part).render(self)
    end

    def template_for_partial(partial)
      @partial_template_cache[partial] ||= Template.new(partial)
    end

    # A {{>*dynamic_partial}} tag translates into a call to this
    # method. The given names are looked up in the context (using the
    # same dotted lookup as regular tags) and the resulting string
    # must be registered in the view's `dynamic_partials` mapping.
    # The mapping - not the context - provides the template source, so
    # template data can never inject template code.
    def dynamic_partial(names, indentation = '')
      mustache = mustache_in_stack
      mapping = mustache.respond_to?(:dynamic_partials) ? mustache.dynamic_partials : nil

      name = dynamic_partial_name(names)
      source = registered_dynamic_partial(mapping, name)

      max = if mustache.respond_to?(:dynamic_partial_max_depth)
        mustache.dynamic_partial_max_depth
      end
      max = nil unless max.is_a?(Integer) && max > 0
      max ||= MAX_DYNAMIC_PARTIAL_DEPTH

      if @dynamic_partial_depth >= max
        raise DynamicPartialRecursionError.new("Dynamic partials nested too deeply (more than #{max} levels)")
      end

      @dynamic_partial_depth += 1
      begin
        # Indent the partial template by the given indentation, just
        # like a standalone static partial.
        part = source.to_s.gsub(/^/, indentation)
        template_for_dynamic_partial(part, mapping).render(self)
      ensure
        @dynamic_partial_depth -= 1
      end
    end

    # Dynamic partial templates are cached by their (indented) source,
    # so a registered fragment keeps its compiled identity across
    # renders while the *selection* is re-resolved every time.
    def template_for_dynamic_partial(partial, mapping)
      @dynamic_partial_template_cache[partial] ||=
        Template.new(partial, :dynamic_partials => mapping)
    end

    # Find the first Mustache in the stack.
    #
    # If we're being rendered inside a Mustache object as a context,
    # we'll use that one.
    #
    # @return [Mustache] First Mustache in the stack.
    #
    def mustache_in_stack
      @mustache_in_stack ||= @stack.find { |frame| frame.is_a?(Mustache) }
    end

    # Allows customization of how Mustache escapes things.
    #
    # @param [Object] value Value to escape.
    #
    # @return [String] Escaped string.
    #
    def escape(value)
      mustache_in_stack.escape(value)
    end

    # Adds a new object to the context's internal stack.
    #
    # @param [Object] new_obj Object to be added to the internal stack.
    #
    # @return [Context] Returns the Context.
    #
    def push(new_obj)
      @stack.unshift(new_obj)
      @mustache_in_stack = nil
      self
    end

    # Removes the most recently added object from the context's
    # internal stack.
    #
    # @return [Context] Returns the Context.
    #
    def pop
      @stack.shift
      @mustache_in_stack = nil
      self
    end

    # Can be used to add a value to the context in a hash-like way.
    #
    # context[:name] = "Chris"
    def []=(name, value)
      push(name => value)
    end

    # Alias for `fetch`.
    def [](name)
      fetch(name, nil)
    end

    # Do we know about a particular key? In other words, will calling
    # `context[key]` give us a result that was set. Basically.
    def has_key?(key)
      fetch(key, false)
    rescue ContextMiss
      false
    end

    # Similar to Hash#fetch, finds a value by `name` in the context's
    # stack. You may specify the default return value by passing a
    # second parameter.
    #
    # If no second parameter is passed (or raise_on_context_miss is
    # set to true), will raise a ContextMiss exception on miss.
    def fetch(name, default = :__raise)
      @stack.each do |frame|
        # Prevent infinite recursion.
        next if frame == self

        value = find(frame, name, :__missing)
        return value if :__missing != value
      end

      if default == :__raise || mustache_in_stack.raise_on_context_miss?
        raise ContextMiss.new("Can't find #{name} in #{@stack.inspect}")
      else
        default
      end
    end

    # Finds a key in an object, using whatever method is most
    # appropriate. If the object is a hash, does a simple hash lookup.
    # If it's an object that responds to the key as a method call,
    # invokes that method. You get the idea.
    #
    # @param [Object] obj The object to perform the lookup on.
    # @param [String,Symbol] key The key whose value you want
    # @param [Object] default An optional default value, to return if the key is not found.
    #
    # @return [Object] The value of key in object if it is found, and default otherwise.
    #
    def find(obj, key, default = nil)

      if mustache_in_stack.context_access_security_level == 5 and !obj.instance_of?(Hash)
        # on level 5, object must be exactly Hash
        return context_level_violation("Detected key access attempt for a non-Hash object using '#{key}'", default)
      end

      return find_in_hash(obj.to_hash, key, default) if obj.respond_to?(:to_hash)

      if mustache_in_stack.context_access_security_level >= 4
        # on levels 4 and 5, method access is not allowed
        return context_level_violation("Detected method access attempt using '#{key}'", default)
      end

      unless obj.respond_to?(key)
        # no match for the key, but it may include a hyphen, so try again replacing hyphens with underscores.
        key = key.to_s.tr('-', '_')
        return default unless obj.respond_to?(key)
      end

      if mustache_in_stack.context_access_security_level >= 3 && !obj.class.instance_methods(false).include?(key.to_sym)
        # on level 3, inherited methods are blocked
        return context_level_violation("Detected inherited method '#{key}'", default)
      end

      if mustache_in_stack.context_access_security_level >= 2 && MethodBlacklist.include?(key.to_s)
        # on levels 2 and 3, reflection-based methods are blacklisted
        return context_level_violation("Detected blacklisted reflection-related key '#{key}'", default)
      end

      meth = obj.method(key) rescue proc { obj.send(key) }
      meth.arity == 1 ? meth.to_proc : meth.call
    end

    def current
      @stack.first
    end


    private

    # Resolves the name of a dynamic partial from the context. The
    # lookup uses the same dotted resolution as regular tags, but the
    # result is required to be a String - no implicit conversion (such
    # as `to_s` or calling a Proc) is ever applied to the found value.
    def dynamic_partial_name(names)
      value = dynamic_partial_lookup(names)

      if :__missing == value
        raise DynamicPartialNameMissing.new("Can't find dynamic partial name '#{names.join('.')}' in context")
      end

      unless value.is_a?(String)
        raise DynamicPartialNameInvalid.new("Dynamic partial name must be a String, got #{value.class}")
      end

      if value.empty?
        raise DynamicPartialNameEmpty.new("Dynamic partial name is empty")
      end

      value
    end

    # Like the dotted lookup the Generator emits for regular tags, but
    # with explicit miss detection so a missing variable can be
    # reported separately from an empty or unregistered name.
    def dynamic_partial_lookup(names)
      first, *rest = names.map { |name| name.to_sym }

      value = begin
        fetch(first, :__missing)
      rescue ContextMiss
        :__missing
      end

      rest.each do |key|
        break if :__missing == value || value.nil?
        value = find(value, key, :__missing)
      end

      value.nil? ? :__missing : value
    end

    # Returns the template source registered under `name` in the
    # caller-provided mapping, raising if the name was not registered.
    def registered_dynamic_partial(mapping, name)
      if mapping && mapping.respond_to?(:key?)
        return mapping[name] if mapping.key?(name)

        symbolized = name.to_sym
        return mapping[symbolized] if mapping.key?(symbolized)
      end

      raise DynamicPartialNameNotRegistered.new("Dynamic partial #{name.inspect} is not registered")
    end

    # Fetches a hash key if it exists, or returns the given default.
    def find_in_hash(obj, key, default)
      return obj[key]      if obj.has_key?(key)
      return obj[key.to_s] if obj.has_key?(key.to_s)
      return obj[key]      if obj.respond_to?(:default_proc) && obj.default_proc && obj[key]

      # If default is :__missing then we are from #fetch which is hunting through the stack
      # If default is nil then we are reducing dot notation
      if :__missing != default && mustache_in_stack.raise_on_context_miss?
        raise ContextMiss.new("Can't find #{key} in #{obj}")
      else
        obj.fetch(key, default)
      end
    end
  end
end
