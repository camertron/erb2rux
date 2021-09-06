require 'action_view'
require 'parser/current'
require 'unparser'

module Erb2Rux
  module ProcessorHelpers
    private

    def send_type_for(node)
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

  # class StripBufferOutputs < ::Parser::AST::Processor
  #   include ProcessorHelpers

  #   def on_send(node)
  #     send_type_for(node) == :string ? :remove : nil
  #   end

  #   def process_all(nodes)
  #     processed_nodes = super
  #     processed_nodes.reject do |pnode|
  #       pnode == :remove
  #     end
  #   end
  # end

  # class ExtractBufferOutputs < ::Parser::AST::Processor
  #   include ProcessorHelpers

  #   attr_reader :src

  #   def initialize
  #     @src = ''
  #   end

  #   def on_send(node)
  #     if stype = send_type_for(node)
  #       _, _, arg, * = *node

  #       case stype
  #         when :string
  #           # only unparse first child to strip off .freeze call
  #           @src << eval(Unparser.unparse(arg.children[0]))
  #         when :echo
  #           # HTML isn't allowed inside rux curly braces without being
  #           # rendered inside a component, so we can remove them. This can
  #           # be fairly lossy, but for most use-cases should be ok. Maybe
  #           # consider printing a warning in the future.
  #           stripped = StripBufferOutputs.new.process(arg)
  #           @src << "<%= #{Unparser.unparse(stripped)} %>"
  #         when :expression
  #           @src << "<% #{Unparser.unparse(node)} %>"
  #       end
  #     end
  #   end
  # end

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

    def close_tag
      @close_tag ||= "</#{component_name}>"
    end

    def open_tag
      @open_tag ||= ''.tap do |open_tag|
        open_tag << "<#{component_name}"
        kwargs = component_kwargs.map do |key, value|
          "#{key}={#{value}}"
        end
        kwargs << "as={\"#{block_arg}\"}" if block_arg
        open_tag << ' ' unless kwargs.empty?
        open_tag << kwargs.join(' ')
        open_tag << '>'
      end
    end
  end

  class RemoveOutputAppends < Parser::TreeRewriter
    include ProcessorHelpers

    def on_send(node)
      if stype = send_type_for(node)
        _, _, arg, * = *node

        case stype
          when :string
            # add 1 to include trailing semicolon
            node_loc = node.location.expression

            loc = ::Parser::Source::Range.new(
              node_loc.source_buffer,
              node_loc.begin_pos,
              node_loc.end_pos + 1
            )

            replace(loc, eval(arg.children[0].location.expression.source))
          when :code
            arg_body = arg.type == :begin ? arg.children[0] : arg
            orig_loc = node.location.expression
            loc = make_range(orig_loc.source_buffer, orig_loc.begin_pos, orig_loc.end_pos + 1)
            replace(loc, arg_body.location.expression.source)
        end
      end
    end
  end

  class IdentifyRubyCode < ::Parser::TreeRewriter
    include ProcessorHelpers

    (instance_methods.grep(/on_/) - [:on_send]).each do |mtd|
      define_method(mtd) do |node|
        binding.pry
        if @in_rux && node.location.expression # unless contains_stype([node])
          code = node.location.expression.source
          ast = ::Parser::CurrentRuby.parse(code)
          buffer = ::Parser::Source::Buffer.new('(rux)', source: code)
          code = RemoveOutputAppends.new.rewrite(buffer, ast)
          replace(node.location.expression, "{#{code}}")
          # wrap(node.location.expression, '{', '}')
          # @in_rux = false
        else
          super(node)
        end
      end
    end

    def contains_stype(nodes)
      nodes.any? do |n|
        next unless n.respond_to?(:children)
        send_type_for(n) || contains_stype(n.children)
      end
    end

    def on_send(node)
      stype = send_type_for(node)
      _, _, arg, * = *node

      case stype
        when :string
          # add 1 to include trailing semicolon
          node_loc = node.location.expression

          loc = ::Parser::Source::Range.new(
            node_loc.source_buffer,
            node_loc.begin_pos,
            node_loc.end_pos + 1
          )

          replace(loc, eval(arg.children[0].location.expression.source))
          @in_rux = true

        when :code
          if arg.type == :block
            if (component_render = identify_component_render(arg))
              # remove append= call
              output_start = node.location.expression.begin_pos
              output_end = node.location.operator.end_pos
              replace(make_range(node.location.expression.source_buffer, output_start, output_end), '')

              # replace block start and end with open/close tags
              replace(component_render.block_end_range, component_render.close_tag)
              replace(component_render.block_range, component_render.open_tag)

              # recursively handle block body
              block_code = component_render.block_body_range.source
              block_ast = ::Parser::CurrentRuby.parse(block_code)
              block_buffer = ::Parser::Source::Buffer.new('(block)', source: block_code)
              block_code = IdentifyRubyCode.new.rewrite(block_buffer, block_ast)
              replace(component_render.block_body_range, block_code)

              # wrap block body in curlies
              wrap(component_render.block_body_range, '{', '}')
            end
          else
            arg_body = arg.type == :begin ? arg.children[0] : arg
            orig_loc = node.location.expression
            loc = make_range(orig_loc.source_buffer, orig_loc.begin_pos, orig_loc.end_pos + 1)
            replace(loc, "{#{arg_body.location.expression.source}}")
          end
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

      source = block_node.location.expression.source_buffer.source

      block_start = block_node.location.expression.begin_pos
      block_stop = if block_arg_node
        block_arg_start = block_arg_node.location.expression.begin_pos
        source.index('|', block_arg_start) + 1
      else
        block_node.location.begin.end_pos
      end

      block_body_start = source.index(/\S/, block_stop)
      block_body_end = source.rindex(/\S/, block_node.location.end.begin_pos - 1) + 1

      buffer = block_node.location.expression.source_buffer

      ComponentRender.new(
        component_name: Unparser.unparse(component_name_node),
        component_kwargs: kwargs,
        block_range: make_range(buffer, block_start, block_stop),
        block_end_range: block_node.location.end,
        block_body_range: make_range(buffer, block_body_start, block_body_end),
        block_arg: block_arg_name
      )
    end
  end

  class ErbPreprocessor
    class << self
      def preprocess(source)
        ruby_code = ActionView::Template::Handlers::ERB::Erubi.new(source).src
        ast = ::Parser::CurrentRuby.parse(ruby_code)
        code_ident = IdentifyRubyCode.new
        buffer = Parser::Source::Buffer.new('(ruby)', source: ruby_code)
        code_ident.rewrite(buffer, ast)
      end
    end
  end
end
