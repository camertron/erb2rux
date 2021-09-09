require 'action_view'
require 'parser'
require 'unparser'

module Erb2Rux
  NodeMeta = Struct.new(:node, :stype, :replacement, :in_code)

  class Transformer
    class << self
      def transform(source)
        # Remove any extra spaces between the ERB tag and the content, eg.
        # "<%= foo %>" becomes "<%=foo%>". ActionView's Erubi parser
        # treats this extra whitespace as part of the output, which results
        # in funky indentation issues.
        source.gsub!(/(<%=?) */, '\1')
        source.gsub!(/ *(%>)/, '\1')

        # This is how Rails translates ERB to Ruby code, so it's probably the
        # way we should do it too. It takes blocks into account, which, TIL, is
        # something regular ERB doesn't do. The resulting ruby code works by
        # appending to an @output_buffer instance variable. Different methods
        # are used for chunks of code vs HTML strings, which allows the
        # transformer to distinguish between them. See #send_type_for for
        # details.
        ruby_code = ActionView::Template::Handlers::ERB::Erubi.new(source).src

        # ActionView adds this final line at the end of all compiled templates,
        # so we need to remmove it.
        ruby_code = ruby_code.chomp('@output_buffer.to_s')
        ast = ::Parser::CurrentRuby.parse(ruby_code)
        rewrite(ast)
      end

      private

      # Determines whether or not the given node is itself a node (i.e. an
      # instance of Parser::AST::Node) that identifies a visible chunk of
      # code in the source buffer. (In addition to being Node instances,
      # children can be strings, symbols, or nil, and sometimes only hold
      # metadata, i.e. don't reference a visible portion of the source).
      def is_node?(obj)
        obj.respond_to?(:children) && obj.location.expression
      end

      def rewrite(node)
        return unless is_node?(node)

        # The "send type" refers to the way this node is being appended to the
        # output buffer. <%= %> tags result in a call to append=, which has a
        # send type of :code. <% %> tags result in no append calls and have a
        # send type of nil. Finally, regular 'ol strings (i.e. HTML) result in
        # a call to safe_append= and have a send type of :string.
        case send_type_for(node)
          when :code
            rewrite_code(node)
          when :string
            rewrite_string(node)
          else
            # Code in <% %> tags should be left as-is. Instead of rewriting it
            # we recurse and process all the children.
            rewrite_children(node)
        end
      end

      def rewrite_code(node)
        # Any node that is passed to this method will be a s(:send) node that
        # identifies a chunk of Ruby code that should be surrounded by Rux
        # braces. The arg below is the argument to the @output_buffer.append=
        # call.
        _, _, arg, * = *node

        # Does this node render a view component?
        if (component_render = identify_component_render(arg))
          _, _, block_body, = *arg

          return arg.location.expression.source.dup.tap do |code|
            # If the render call has a block...
            if block_body
              # ...replace the end statement with the closing tag, recursively
              # rewrite the block's body, and replace the render call with the
              # opening tag. Do these things in reverse order so all the ranges
              # are valid.
              code[component_render.block_end_range] = component_render.close_tag
              leading_ws, body, trailing_ws = ws_split(rewrite(block_body))

              code[component_render.block_body_range] = if body.empty?
                "#{leading_ws}#{trailing_ws}"
              else
                "#{leading_ws}{#{body}}#{trailing_ws}"
              end

              code[component_render.send_range] = component_render.open_tag
            else
              # ...otherwise only replace the render call and self-close the tag.
              code[component_render.send_range] = component_render.self_closing_tag
            end
          end
        end

        # ActionView wraps code in parens (eg. @output_buffer.append= ( foo ))
        # which results in an extra s(:begin) node wrapped around the code node.
        # Strip it off.
        arg_body = arg.type == :begin ? arg.children[0] : arg
        rewrite(arg_body)
      end

      def rewrite_string(node)
        # Any node that is passed to this method will be a s(:send) node that
        # identifies a chunk of HTML. The arg below is the argument to the
        # @output_buffer.safe_append= call.
        _, _, arg, * = *node

        # Strip off quotes.
        str = arg.children[0].location.expression.source[1..-2]

        # Rux leaves HTML as-is, i.e. doesn't quote it.
        unless tag_start?(str)
          # ActionView appends every literal string it finds in the ERB source,
          # which includes newlines and other incidental whitespace that we
          # programmers frequently use to indent our code and otherwise make it
          # look readable to other humans. This extra whitespace isn't part of
          # the string itself, but because there's nothing in ERB to indicate
          # where whitespace should stop and the string should start,
          # ActionView just sort of smushes it all together. The whitespace is
          # important for the aforementioned formatting reasons, so it
          # shouldn't just be thrown away. Instead, the following lines extract
          # the important string part along with the leading and trailing
          # whitespace, then quote the string and stick all the parts back
          # together. Seems to work ok.
          leading_ws, str, trailing_ws = ws_split(str)
          str = "#{leading_ws}#{rb_quote(str)}#{trailing_ws}"
        end

        str
      end

      def tag_start?(str)
        str.strip.start_with?('<')
      end

      def ws_split(str)
        leading_ws = str.match(/\A(\s*)/)
        # Pass the second arg here to avoid considering the same whitespace
        # as both leading _and_ trailing, as in the case where the string is
        # entirely whitespace, etc.
        trailing_ws = str.match(/(\s*)\z/, leading_ws.end(0))
        middle = str[leading_ws.end(0)...(trailing_ws.begin(0))]
        [leading_ws.captures[0], middle, trailing_ws.captures[0]]
      end

      # Because we have to perform replacements in reverse order to avoid
      # invalidating the ranges that come later in the source, it's impossible
      # to know whether a particular node is already wrapped in Rux curly
      # braces or not. In other words, whether or not the current node exists
      # inside a code block is entirely determined by the nodes that come
      # before it, which cannot be considered when iterating in reverse order.
      # To mitigate this problem, we first iterate in a forward manner and
      # accrue metadata for each node. The NodeMeta struct holds a reference
      # to the node, meaning that the replacement algorithm can simply iterate
      # backwards through a list of them.
      def calc_node_meta(nodes)
        # Start out assuming we're in code. This is also what the Rux parser
        # does.
        in_code = true

        nodes.each_with_object([]) do |child_node, memo|
          next unless is_node?(child_node)

          stype = send_type_for(child_node)
          replacement = rewrite(child_node)

          memo << NodeMeta.new(child_node, stype, replacement, in_code)

          case stype
            when :string
              if tag_start?(replacement)
                # If we're inside an HTML tag, that must mean we're not in a
                # code block anymore.
                in_code = false
              end
            when :code
              in_code = true
          end
        end
      end

      def rewrite_children(node)
        node_loc = node.location.expression
        child_meta = calc_node_meta(node.children)

        node_loc.source.dup.tap do |result|
          # The replacement algorithm needs to be able to consider the previous
          # node's metadata, so we use a sliding window of 2.
          reverse_each_cons(2, child_meta) do |prev, cur|
            next unless cur

            child_loc = cur.node.location.expression

            # A code node inside HTML who's replacement isn't HTML. Needs to be
            # wrapped in Rux curlies.
            if (cur.stype == :code || cur.stype == nil) && !cur.in_code && !tag_start?(cur.replacement)
              cur.replacement = "{#{cur.replacement}}"
            end

            # ERB nodes that occur right next to each other should be concatenated.
            # Eg: foo <%= bar %> should result in "foo" + bar.
            # This check makes sure that:
            # 1. Both the previous and current nodes are ERB code (i.e. are
            #    :code or :string).
            # 2. Both the previous and current nodes are in a code block. If
            #    they're not, it doesn't make much sense to concatenate them
            #    using Ruby's `+' operator.
            # 3. Both the previous and current nodes aren't 100% whitespace,
            #    which would indicate they're for formatting purposes and don't
            #    contain actual code.
            should_concat =
              prev &&
              cur.stype &&
              prev.stype &&
              cur.in_code &&
              prev.in_code &&
              !cur.replacement.strip.empty? &&
              !prev.replacement.strip.empty?

            if should_concat
              cur.replacement = " + #{cur.replacement}"
            end

            begin_pos = child_loc.begin_pos - node_loc.begin_pos
            end_pos = child_loc.end_pos - node_loc.begin_pos
            # Trim off those pesky trailing semicolons ActionView adds.
            end_pos += 1 if result[end_pos] == ';'
            result[begin_pos...end_pos] = cur.replacement
          end
        end
      end

      # Iterates backwards over the `items` enumerable and yields a sliding
      # window of `size` elements.
      #
      # For example, reverse_each_cons(3, %w(a b c d)) yields the following:
      #
      # ["d", nil, nil]
      # ["c", "d", nil]
      # ["b", "c", "d"]
      # ["a", "b", "c"]
      # [nil, "a", "b"]
      # [nil, nil, "a"]
      def reverse_each_cons(size, items)
        slots = Array.new(size)
        enum = items.reverse_each
        stops = nil

        loop do
          item = begin
            stops += 1 if stops
            stops ? nil : enum.next
          rescue StopIteration
            stops = 1
            nil
          end

          slots.unshift(item)
          slots.pop

          yield slots

          # It's not useful to anybody to yield an array of all nils.
          break if stops == size - 1
        end
      end

      def identify_component_render(node)
        send_node, *block_args_node = *node
        block_arg_nodes = block_args_node[0]&.children || []
        # Doesn't make sense for a component render to have more than one
        # block argument.
        return if block_arg_nodes.size > 1

        block_arg_node, = *block_arg_nodes
        return if block_arg_node && block_arg_node.type != :arg

        block_arg_name, = *block_arg_node

        receiver_node, method_name, *render_args = *send_node
        # There must be no receiver (i.e. no dot), the method name must be
        # "render," and it must take exactly one argument.
        return if receiver_node || method_name != :render
        return if !render_args || render_args.size != 1

        render_arg, = *render_args
        # The argument passed to render must be a s(:send) node, which
        # indicates the presence of .new being called on a component class.
        # This seems fine for now, but might need to change if we find there
        # are other common ways to pass component instances to render.
        return if render_arg.type != :send

        component_name_node, _, *component_args = *render_arg
        # The Parser gem treats keyword args as a single arg, and since Rux
        # doesn't allow positional arguments, it's best to leave non-conforming
        # renders alone and bail out here.
        return if component_args.size > 1

        component_kwargs, = *component_args

        kwargs = if component_kwargs
          # Whatever this first argument is, it'd better be a hash. This is how
          # the Parser gem parses keyword arguments, even though kwargs are no
          # longer treated as hashes in modern Rubies.
          return unless component_kwargs.type == :hash

          # Build up an array of 2-element [key, value] arrays
          component_kwargs.children.map do |component_kwarg|
            key, value = *component_kwarg
            return unless [:sym, :str].include?(key.type)

            [key.children[0], Unparser.unparse(value)]
          end
        else
          # It's perfectly ok for components not to accept any args
          []
        end

        source = node.location.expression.source

        # This is the base position all other positions should start from.
        # The Parser gem's position information is all absolute, i.e.
        # measured from the beginning of the original source buffer. We want to
        # consider only this one node, meaning all positions must be adjusted
        # so they are relative to it.
        start = node.location.expression.begin_pos
        send_stop = if block_arg_node
          # Annoyingly, the Parser gem doesn't include the trailing block
          # terminator pipe in location.end. We have to find it manually with
          # this #index call instead. What a pain.
          block_arg_start = block_arg_node.location.expression.begin_pos - start
          source.index('|', block_arg_start) + 1
        else
          # If we get to this point and there is no block passed to render,
          # that means we're looking at the surrounding block Erubi adds
          # around Ruby code (effectively surrounding it with parens). In such
          # a case, the "begin" location points to the opening left paren. If
          # instead there _is_ a block passed to render, the "begin" location
          # points to the "do" statement. Truly confusing, but here we are.
          if node.location.begin.source == 'do'
            node.location.begin.end_pos - start
          else
            node.location.expression.end_pos - start
          end
        end

        block_end_range = nil
        block_body_range = nil

        if node.type == :block
          # Use index here to find the first non-whitespace character after the
          # render call, as well as the first non-whitespace character before
          # the end of the "end" statement.
          block_body_start = source.index(/\S/, send_stop)
          block_body_end = source.rindex(/\S/, node.location.end.begin_pos - start - 1) + 1

          block_end = node.location.end
          block_end_range = (block_end.begin_pos - start)...(block_end.end_pos - start)
          block_body_range = block_body_start...block_body_end
        end

        return ComponentRender.new(
          component_name: Unparser.unparse(component_name_node),
          component_kwargs: kwargs,
          send_range: 0...send_stop,
          block_end_range: block_end_range,
          block_body_range: block_body_range,
          block_arg: block_arg_name
        )
      end

      # Escapes double quotes, then double quotes the result.
      def rb_quote(str)
        return '' if !str || str.empty?
        "\"#{str.gsub("\"", "\\\"")}\""
      end

      def send_type_for(node)
        return unless is_node?(node)

        receiver_node, method_name, = *node
        return unless is_node?(receiver_node)

        # Does this node indicate a method called on the @output_buffer
        # instance variable?
        is_buffer_append = receiver_node.type == :ivar &&
          receiver_node.children[0] == :@output_buffer

        return unless is_buffer_append

        case method_name
          when :safe_append=
            :string
          when :append=
            :code
        end
      end
    end
  end
end