module Erb2Rux
  class NodeCursor
    def initialize(nodes)
      @nodes = nodes
      @counter = 0
    end

    def current
      @nodes[@counter]
    end

    def consume(*types)
      [].tap do |result_set|
        while @counter < @nodes.size
          break unless types.include?(current.type)

          result_set << current
          @counter += 1
        end
      end
    end
  end

  class RuxEmitter
    def initialize
      @result = ''
    end

    def emit(doc)
      emit_children(doc)
    end

    private

    def emit_children(node)
      cursor = NodeCursor.new(node.children)

      case cursor.current.type
        when :ruby, :ruby_echo
          emit_ruby(cursor)
      end
    end

    def emit_ruby(cursor)
      @result << cursor.current.code

      while [:ruby, :ruby_echo, :text].include?(cursor.current.type)
        case cursor.current.type
      end
    end
  end
end