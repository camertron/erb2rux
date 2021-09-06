require 'parser/current'
require 'unparser'

module Erb2Rux
  class ComponentRender
    attr_reader :component_name, :component_kwargs
    attr_reader :block_range, :block_end_range, :block_body_range, :block_arg

    def initialize(component_name:, component_kwargs:, block_range:, block_end_range:, block_body_range:, block_arg:)
      @component_name = component_name
      @component_kwargs = component_kwargs
      @block_range = block_range
      @block_end_range = block_end_range
      @block_body_range = block_body_range
      @block_arg = block_arg
    end
  end

  class IdentifyComponentRenders < ::Parser::AST::Processor
    attr_reader :component_renders

    def initialize
      @component_renders = []
    end

    def on_block(block_node)
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

      block_start = block_node.location.expression.begin_pos
      block_stop = if block_arg_node
        block_arg_start = block_arg_node.location.expression.begin_pos - block_start
        block_arg_end = block_node.location.expression.source.index('|', block_arg_start)
        block_arg_end + block_start
      else
        block_node.location.begin.end_pos
      end

      block_body_start = block_node.location.expression.source.index(/\S/, block_stop + 1)
      block_body_end = block_node.location.expression.source.rindex(/\S/, block_node.location.end.begin_pos - 1)

      component_renders << ComponentRender.new(
        component_name: Unparser.unparse(component_name_node),
        component_kwargs: kwargs,
        block_range: block_start..block_stop,
        block_end_range: block_node.location.end.to_range,
        block_body_range: block_body_start..block_body_end,
        block_arg: block_arg_name
      )
    end
  end

  class Transpiler
    class << self
      def transpile(ruby_code)
        ast = ::Parser::CurrentRuby.parse(ruby_code)
        identify = IdentifyComponentRenders.new
        identify.process(ast)

        if identify.component_renders.empty?
          return "{#{ruby_code}}"
        end

        ruby_code.dup.tap do |result|
          identify.component_renders.reverse_each do |render|
            result[render.block_end_range] = "</#{render.component_name}>"
            result.insert(render.block_body_range.last + 1, '}')
            result.insert(render.block_body_range.first, '{')
            open_tag = "<#{render.component_name}"
            kwargs = render.component_kwargs.map do |key, value|
              "#{key}={#{value}}"
            end
            kwargs << "as={\"#{render.block_arg}\"}" if render.block_arg
            open_tag << ' ' unless kwargs.empty?
            open_tag << kwargs.join(' ')
            open_tag << '>'
            result[render.block_range] = open_tag
          end
        end
      end
    end
  end
end