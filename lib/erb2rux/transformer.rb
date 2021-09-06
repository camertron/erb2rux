require 'action_view'
require 'parser'
require 'unparser'

module Erb2Rux
  NodeMeta = Struct.new(:node, :stype, :replacement, :in_code)

  class Transformer
    class << self
      def transform(source)
        source.gsub!(/(<%=?) */, '\1')
        source.gsub!(/ *(%>)/, '\1')

        ruby_code = ActionView::Template::Handlers::ERB::Erubi.new(source).src
        ruby_code = ruby_code.chomp("\n@output_buffer.to_s")
        ast = ::Parser::CurrentRuby.parse(ruby_code)
        rewrite_children(ast)
      end

      private

      def is_node?(obj)
        obj.respond_to?(:children) && obj.location.expression
      end

      def rewrite(node)
        return unless is_node?(node)

        case send_type_for(node)
          when :code
            rewrite_code(node)
          when :string
            rewrite_string(node)
          else
            rewrite_children(node)
        end
      end

      def rewrite_code(node)
        _, _, arg, * = *node

        if arg.type == :block
          _, _, block_body, = *arg

          if (component_render = identify_component_render(arg))
            return arg.location.expression.source.dup.tap do |code|
              code[component_render.block_end_range] = component_render.close_tag
              leading_ws, body, trailing_ws = ws_split(rewrite(block_body))
              code[component_render.block_body_range] = "#{leading_ws}{#{body}}#{trailing_ws}"
              code[component_render.block_range] = component_render.open_tag
            end
          end
        end

        arg_body = arg.type == :begin ? arg.children[0] : arg
        rewrite(arg_body)
      end

      def rewrite_string(node)
        _, _, arg, * = *node
        str = arg.children[0].location.expression.source[1..-2]

        unless str.strip.start_with?('<')
          leading_ws, str, trailing_ws = ws_split(str)
          str = "#{leading_ws}#{rb_quote(str)}#{trailing_ws}"
        end

        str
      end

      def ws_split(str)
        leading_ws = str.match(/\A(\s*)/)
        trailing_ws = str.match(/(\s*)\z/, leading_ws.end(0))
        middle = str[leading_ws.end(0)...(trailing_ws.begin(0))]
        [leading_ws.captures[0], middle, trailing_ws.captures[0]]
      end

      def calc_node_meta(nodes)
        in_code = true

        nodes.each_with_object([]) do |child_node, memo|
          next unless is_node?(child_node)

          stype = send_type_for(child_node)
          replacement = rewrite(child_node)

          memo << NodeMeta.new(child_node, stype, replacement, in_code)

          case stype
            when :string
              if replacement.strip.start_with?('<')
                in_code = false
              end
            when :code
              in_code = true
          end
        end
      end

      def rewrite_children(node)
        node_loc = node.location.expression
        child_nodes = calc_node_meta(node.children)

        node_loc.source.dup.tap do |result|
          reverse_each_cons(2, child_nodes) do |prev, cur|
            next unless cur

            child_loc = cur.node.location.expression

            if cur.stype == :code && !cur.in_code
              cur.replacement = "{#{cur.replacement}}"
            end

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
            end_pos += 1 if result[end_pos] == ';'
            result[begin_pos...end_pos] = cur.replacement
          end
        end
      end

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

          break if stops == size - 1
        end
      end

      def identify_component_render(block_node)
        send_node, *block_args_node = *block_node
        block_arg_nodes = block_args_node[0]&.children || []
        return if block_arg_nodes.size > 1

        block_arg_node, = *block_arg_nodes
        return if block_arg_node && block_arg_node.type != :arg

        block_arg_name, = *block_arg_node

        receiver_node, method_name, *render_args = *send_node
        return if receiver_node || method_name != :render
        return if !render_args || render_args.size != 1

        render_arg, = *render_args
        return if render_arg.type != :send

        component_name_node, _, *component_args = *render_arg
        return if component_args.size > 1

        component_kwargs, = *component_args

        kwargs = if component_kwargs
          return unless component_kwargs.type == :hash

          component_kwargs.children.map do |component_kwarg|
            key, value = *component_kwarg
            return unless [:sym, :str].include?(key.type)

            [key.children[0], Unparser.unparse(value)]
          end
        else
          []
        end

        source = block_node.location.expression.source

        block_start = block_node.location.expression.begin_pos
        block_stop = if block_arg_node
          block_arg_start = block_arg_node.location.expression.begin_pos - block_start
          source.index('|', block_arg_start) + 1
        else
          block_node.location.begin.end_pos - block_start
        end

        block_body_start = source.index(/\S/, block_stop)
        block_body_end = source.rindex(/\S/, block_node.location.end.begin_pos - block_start - 1) + 1

        block_end = block_node.location.end

        ComponentRender.new(
          component_name: Unparser.unparse(component_name_node),
          component_kwargs: kwargs,
          block_range: 0...block_stop,
          block_end_range: (block_end.begin_pos - block_start)...(block_end.end_pos - block_start),
          block_body_range: block_body_start...block_body_end,
          block_arg: block_arg_name
        )
      end

      def rb_quote(str)
        return '' if !str || str.empty?
        "\"#{str.gsub("\"", "\\\"")}\""
      end

      def send_type_for(node)
        return unless node.respond_to?(:children)

        receiver_node, method_name, = *node
        return unless receiver_node.respond_to?(:children)

        is_buffer_append = receiver_node&.type == :ivar &&
          receiver_node&.children&.[](0) == :@output_buffer

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