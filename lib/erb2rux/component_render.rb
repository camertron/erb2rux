module Erb2Rux
  class ComponentRender
    attr_reader :component_name, :component_kwargs
    attr_reader :send_range, :block_end_range, :block_body_range, :block_arg

    def initialize(component_name:, component_kwargs:, send_range:, block_end_range:, block_body_range:, block_arg:)
      @component_name = component_name
      @component_kwargs = component_kwargs
      @send_range = send_range
      @block_end_range = block_end_range
      @block_body_range = block_body_range
      @block_arg = block_arg
    end

    def close_tag
      @close_tag ||= "</#{component_name}>"
    end

    def open_tag
      @open_tag ||= ''.tap do |result|
        result << "<#{component_name}"
        result << ' ' unless kwargs.empty?
        result << kwargs
        result << '>'
      end
    end

    def self_closing_tag
      @self_closing_tag ||= ''.tap do |result|
        result << "<#{component_name}"
        result << ' ' unless kwargs.empty?
        result << kwargs
        result << ' />'
      end
    end

    private

    def kwargs
      @kwargs = begin
        kwargs = component_kwargs.map do |key, value|
          "#{key}={#{value}}"
        end
        kwargs << "as={\"#{block_arg}\"}" if block_arg
        kwargs.join(' ')
      end
    end
  end
end
