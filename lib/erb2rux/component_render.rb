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
end
