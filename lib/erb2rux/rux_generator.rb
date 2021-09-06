module Erb2Rux
  class RuxGenerator
    class << self
      def generate(doc)
        new(doc).generate
      end
    end

    attr_reader :doc

    def initialize(doc)
      @doc = doc
    end

    def generate
      @lines = []

      doc.children.each do |child_node|
        visit(child_node, 0)
      end

      @lines.join("\n")
    end

    private

    def visit(node, level)
      case node.type
        when :tag
          visit_tag(node, level)
        when :ruby
          visit_ruby(node, level)
      end
    end

    def visit_tag(node, level)
      tag_str = "<#{node.name}"

      if node.self_closed?
        tag_str << ' />'
      else
        tag_str << '>'
      end

      @lines.concat(indent(tag_str, level))

      node.children.each do |child_node|
        visit(child_node, level + 1)
      end

      unless node.self_closed?
        @lines.concat(indent("</#{node.name}>", level))
      end
    end

    def visit_ruby(node, level)
      rux_code = Transpiler.transpile(node.code.strip)
      @lines.concat(indent(rux_code, level))
    end

    def indent(text, level)
      lines = text.split("\n")
      leading_ws = lines.map { |line| line.index(/\S/) }
      min_leading_ws = leading_ws.min
      lines.map do |line|
        indent_line(line[min_leading_ws..-1], level)
      end
    end

    def indent_line(text, level)
      "#{' ' * level * 2}#{text}"
    end
  end
end
