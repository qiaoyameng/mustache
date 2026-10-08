require 'mustache/parser'

class Mustache
  # SourceMapRenderer renders a template by walking its token tree
  # directly (instead of compiling it to Ruby like Mustache::Generator)
  # and records which source region produced every byte of the output.
  #
  # The rendered string is byte-identical to the one produced by
  # Mustache::Template#render. Along with it, a segment table is
  # returned which fully covers the output. Each segment is a Hash:
  #
  #   {
  #     :range      => 0...5,       # byte offsets into the output
  #     :kind       => :static,     # :static, :etag, :utag,
  #                                 # :indentation or :lambda
  #     :source     => { ... },     # where these bytes came from
  #     :call_chain => [ ... ],     # partials leading to :source,
  #                                 # outermost first ([] for the main template)
  #   }
  #
  # A source identifies a template (or a dynamic, lambda-generated
  # template) and, when known, a position inside of it:
  #
  #   { :type => :template, :name => "emails/welcome.mustache",
  #     :line => 3, :column => 4 }
  #   { :type => :partial,  :name => "header", :line => 1, :column => 0 }
  #   { :type => :lambda,   :name => "items" }
  #
  # :line is 1-based and :column 0-based. Both are nil when unknown.
  # Lambda sources never carry file positions of the original
  # template: their content is generated at runtime, so any position
  # would be a lie. Positions inside a lambda's dynamic template are
  # relative to that generated string.
  #
  # Adjacent segments with the same kind, source and call chain are
  # merged. Variable values are never stored in the segment table.
  class SourceMapRenderer
    def initialize(options = {})
      @options = options
      @static_lambdas = options[:static_lambdas] == true
    end

    # Renders `template` (a Mustache::Template) against `context` (a
    # Mustache::Context). `source` identifies the template itself,
    # e.g. { :type => :template, :name => "welcome" }.
    #
    # Returns [output, segments].
    def render(template, context, source = nil)
      @output = +""
      @segments = []

      source ||= { :type => :template, :name => '(template)' }
      env = env_for(template.source, source)
      render_tokens(parse(template.source), context, env, [])

      [@output, @segments]
    end


    private


    # An env describes the template whose tokens are being rendered:
    #
    #   :id     - source identity Hash shared by all its segments
    #   :text   - original source text (used for line/column lookups)
    #   :parsed - the text that was actually parsed (source text with
    #             standalone indentation applied, for partials)
    #   :indent - nil, or a Hash describing inserted indentation:
    #     :ranges      - sorted [[byte_start, byte_length], ...] in :parsed
    #     :indentation - the inserted indentation String
    #     :source      - source Hash for indentation segments (the {{>}} tag)
    #     :call_chain  - call chain for indentation segments
    def env_for(text, id)
      { :id => id, :text => text, :parsed => text, :indent => nil }
    end

    def parse(src, delims = nil)
      options = @options.merge(:record_offsets => true)
      # Partial inlining would erase the partials' own source
      # identity, so the map renderer always resolves them at runtime.
      options.delete(:inline_partials_at_compile_time)

      parser = Mustache::Parser.new(options)
      parser.otag, parser.ctag = delims if delims
      parser.compile(src)
    end

    def render_tokens(tokens, ctx, env, call_chain)
      tokens[1..-1].each do |token|
        case token[0]
        when :static
          emit_static(token[1], token[2], env, call_chain)
        when :mustache
          send("on_#{token[1]}", token, ctx, env, call_chain)
        end
      end
    end

    # Fetches a (possibly dotted) name from the context, mirroring
    # Mustache::Generator#on_fetch.
    def fetch_value(ctx, names)
      return ctx.current if names.empty?

      initial, *rest = names.map { |n| n.to_sym }
      rest.reduce(ctx[initial]) { |value, key| value && ctx.find(value, key) }
    end

    def on_etag(token, ctx, env, call_chain)
      names = token[2][2]
      value = fetch_value(ctx, names)

      if value.is_a?(Proc)
        value = call_value_lambda(value, ctx)
        emit(ctx.escape(value).to_s, :etag, lambda_id(names), call_chain)
      else
        emit(ctx.escape(value).to_s, :etag, tag_source(env, token[3]), call_chain)
      end
    end

    def on_utag(token, ctx, env, call_chain)
      names = token[2][2]
      value = fetch_value(ctx, names)

      if value.is_a?(Proc)
        value = call_value_lambda(value, ctx)
        emit(value.to_s, :utag, lambda_id(names), call_chain)
      else
        emit(value.to_s, :utag, tag_source(env, token[3]), call_chain)
      end
    end

    def on_section(token, ctx, env, call_chain)
      names = token[2][2]
      content = token[4]
      raw = token[5]
      delims = token[6]
      value = fetch_value(ctx, names)

      case value
      when NilClass, FalseClass
        nil
      when TrueClass
        render_tokens(content, ctx, env, call_chain)
      when Proc
        if @static_lambdas
          inner = capture { render_tokens(content, ctx, env, call_chain) }
          emit(value.call(inner).to_s, :lambda, lambda_id(names), call_chain)
        else
          dynamic = value.call(raw).to_s
          lambda_env = env_for(dynamic, lambda_id(names))
          render_tokens(parse(dynamic, delims), ctx.dup, lambda_env, call_chain)
        end
      when Array, Enumerator, Mustache::Enumerable
        value.each do |item|
          ctx.push(item)
          begin
            render_tokens(content, ctx, env, call_chain)
          ensure
            ctx.pop
          end
        end
      else
        ctx.push(value)
        begin
          render_tokens(content, ctx, env, call_chain)
        ensure
          ctx.pop
        end
      end
    end

    def on_inverted_section(token, ctx, env, call_chain)
      names = token[2][2]
      value = fetch_value(ctx, names)

      if value.nil? || value == false || (value.class != String && value.respond_to?(:empty?) && value.empty?)
        render_tokens(token[4], ctx, env, call_chain)
      end
    end

    def on_partial(token, ctx, env, call_chain)
      name = token[2]
      offset = token[3]
      indentation = token[4] || ''

      # Same lookup the compiled templates perform via Context#partial.
      part = ctx.mustache_in_stack.partial(name.to_sym).to_s

      partial_id = { :type => :partial, :name => name }
      sub_env = env_for(part, partial_id)

      unless indentation.empty?
        indented, ranges = indent_text(part, indentation)
        sub_env[:parsed] = indented
        sub_env[:indent] = {
          :ranges => ranges,
          :indentation => indentation,
          :source => tag_source(env, offset),
          :call_chain => call_chain,
        }
      end

      render_tokens(parse(sub_env[:parsed]), ctx, sub_env, call_chain + [partial_id])
    end

    # Renders the block into a throwaway buffer and returns the
    # resulting String, discarding any segments.
    def capture
      saved_output, saved_segments = @output, @segments
      @output = +""
      @segments = []
      yield
      @output
    ensure
      @output = saved_output
      @segments = saved_segments
    end

    # Calls a lambda found in a variable position exactly once, the
    # same way the compiled templates do.
    def call_value_lambda(value, ctx)
      if @static_lambdas
        value.call
      else
        Mustache::Template.new(value.call.to_s).render(ctx.dup)
      end
    end

    def lambda_id(names)
      { :type => :lambda, :name => names.join('.') }
    end

    # Source Hash for a tag located at `offset` ([line, byte column])
    # in the current env. The Parser computes columns on the
    # BINARY-duped source, so they are byte-based; they are converted
    # to character columns here. Inserted indentation is subtracted
    # so positions point into the original partial source.
    def tag_source(env, offset)
      return env[:id].dup if offset.nil?

      line, byte_column = offset
      pos = line_starts(env[:parsed])[line - 1].to_i + byte_column
      pos -= indent_bytes_before(env[:indent][:ranges], pos) if env[:indent]
      line, column = line_col(env[:text], pos)
      env[:id].merge(:line => line, :column => column)
    end

    # Source Hash for static text starting at byte `pos` in the parsed
    # source. Indentation bytes inserted before `pos` are subtracted
    # so positions point into the original partial source.
    def static_source(env, pos)
      return env[:id].dup if pos.nil?

      pos -= indent_bytes_before(env[:indent][:ranges], pos) if env[:indent]
      line, column = line_col(env[:text], pos)
      env[:id].merge(:line => line, :column => column)
    end

    def emit_static(text, pos, env, call_chain)
      indent = env[:indent]

      if indent.nil? || pos.nil?
        emit(text, :static, static_source(env, pos), call_chain)
        return
      end

      cursor = 0 # byte offset within text
      indent[:ranges].each do |start, length|
        next if start + length <= pos
        break if start >= pos + text.bytesize

        from = [start, pos].max - pos
        to = [start + length, pos + text.bytesize].min - pos

        if from > cursor
          emit(text.byteslice(cursor, from - cursor), :static,
               static_source(env, pos + cursor), call_chain)
        end
        emit(text.byteslice(from, to - from), :indentation,
             indent[:source], indent[:call_chain])
        cursor = to
      end

      if cursor < text.bytesize
        emit(text.byteslice(cursor, text.bytesize - cursor), :static,
             static_source(env, pos + cursor), call_chain)
      end
    end

    # Appends text to the output and records a segment covering it,
    # merging with the previous segment when both describe the same
    # source. Every appended byte is covered by exactly one segment.
    def emit(text, kind, source, call_chain)
      return if text.nil? || text.empty?

      start = @output.bytesize
      @output << text

      last = @segments.last
      if last &&
         last[:kind] == kind &&
         last[:source] == source &&
         last[:call_chain] == call_chain
        last[:range] = last[:range].begin...@output.bytesize
      else
        @segments << {
          :range => start...@output.bytesize,
          :kind => kind,
          :source => source,
          :call_chain => call_chain,
        }
      end
    end

    # Replicates `source.gsub(/^/, indentation)` and records the byte
    # ranges of the inserted indentation in the resulting String.
    def indent_text(source, indentation)
      binary = source.b

      points = [0]
      index = -1
      while (index = binary.index("\n", index + 1))
        points << index + 1 if index + 1 < binary.bytesize
      end

      out = +""
      ranges = []
      last = 0
      points.each do |point|
        out << binary[last...point]
        ranges << [out.bytesize, indentation.bytesize]
        out << indentation
        last = point
      end
      out << binary[last..-1].to_s

      [out.force_encoding(source.encoding), ranges]
    end

    # Total number of indentation bytes inserted before byte `pos`.
    def indent_bytes_before(ranges, pos)
      sum = 0
      ranges.each do |start, length|
        break if start + length > pos
        sum += length
      end
      sum
    end

    # Byte offsets at which each line of `text` starts.
    def line_starts(text)
      starts = [0]
      binary = text.b
      index = -1
      while (index = binary.index("\n", index + 1))
        starts << index + 1
      end
      starts
    end

    # Converts a byte offset in `text` to a [line, column] pair.
    # Lines are 1-based, columns 0-based and counted in characters.
    def line_col(text, pos)
      prefix = text.byteslice(0, pos).to_s.force_encoding(text.encoding)
      newline = prefix.rindex("\n")
      column = newline ? prefix.length - newline - 1 : prefix.length
      [prefix.count("\n") + 1, column]
    end
  end
end
