require 'parser'

module Erb2Rux
  class Transformer
    module ProcessorHelpers
      private

      def send_type_for(node)
        return unless node.respond_to?(:children)

        receiver_node, method_name, = *node
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

      def make_range(buffer, start, stop)
        ::Parser::Source::Range.new(buffer, start, stop)
      end
    end

    class RubyRewriter < ::Parser::TreeRewriter
      include ProcessorHelpers

      def on_send(node)
        stype = send_type_for(node)
        node_loc = node.location.expression
        _, _, arg, * = *node

        case stype
          when :string
            # add 1 to include trailing semicolon
            loc = ::Parser::Source::Range.new(
              node_loc.source_buffer,
              node_loc.begin_pos,
              node_loc.end_pos + 1
            )

            ruby_str = eval(arg.children[0].location.expression.source)
            _, leading_ws, str, trailing_ws = ruby_str.split(/\A(\s*)(.*)(\s*)\z/)
            replace(loc, "#{leading_ws}#{escape(str)}#{trailing_ws}")

          when :code
            repl_node = if arg
              arg_body = arg.type == :begin ? arg.children[0] : arg
            else
              node
            end

            # replace(node_loc, Transformer.rewrite(::Parser::AST::Node.new(:begin, [repl_node])))
            replace(node_loc, Transformer.rewrite(repl_node))
        end
      end

      private

      def escape(str)
        return '' unless str
        "\"#{str.gsub("\"", "\\\"")}\""
      end
    end

    class << self
      include ProcessorHelpers

      def transform(source)
        ruby_code = ActionView::Template::Handlers::ERB::Erubi.new(source).src
        ast = ::Parser::CurrentRuby.parse(ruby_code)
        rewrite(ast)
      end

      def rewrite(node)
        replacements = []

        node.children.each do |child_node|
          case send_type_for(child_node)
            when :code
              node_loc = child_node.location.expression
              range = node_loc.begin_pos...(node_loc.end_pos + 1)
              source = child_node.location.expression.source_buffer.source[range]
              ast = ::Parser::CurrentRuby.parse(source)
              buffer = Parser::Source::Buffer.new('(ruby)', source: source)
              code = RubyRewriter.new.rewrite(buffer, ast)
              replacements << ["{#{code}}", child_node.location.expression.to_range]

            when :string
              _, _, arg, * = *child_node
              next unless arg

              str = eval(arg.children[0].location.expression.source)
              replacements << [str, child_node.location.expression.to_range]

            else
              if child_node.respond_to?(:children)
                replacements << [rewrite(child_node), child_node.location.expression.to_range]
              end
          end
        end

        node.location.expression.source.dup.tap do |source|
          replacements.reverse_each do |str, range|
            source[range] = str
          end
        end
      end
    end
  end
end