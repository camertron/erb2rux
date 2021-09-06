require 'better_html'
require 'better_html/parser'

module Erb2Rux
  class DocumentNode
    attr_reader :children

    def initialize
      @children = []
    end

    def type
      :document
    end
  end

  class TagNode
    attr_reader :name, :attributes, :children
    attr_accessor :closed, :self_closed

    alias_method :closed?, :closed
    alias_method :self_closed?, :self_closed

    def initialize(name, attributes)
      @name = name
      @attributes = attributes
      @children = []
      @closed = false
      @self_closed = false
    end

    def type
      :tag
    end
  end

  class QuoteNode
    attr_reader :text

    def initialize(text)
      @text = text
    end

    def type
      :quote
    end
  end

  class TextNode
    attr_reader :text

    def initialize(text)
      @text = text
    end

    def type
      :text
    end
  end

  class RubyEchoNode
    attr_reader :code

    def initialize(code)
      @code = code
    end

    def type
      :ruby_echo
    end
  end

  class RubyNode
    attr_reader :code

    def initialize(code)
      @code = code
    end

    def type
      :ruby
    end
  end

  class ErbParser
    class << self
      def parse(source)
        buffer = ::Parser::Source::Buffer.new('(source)', source: source)
        ast = BetterHtml::Parser.new(buffer).ast
        visit_document(ast)
      end

      private

      def visit_document(node)
        DocumentNode.new.tap do |doc|
          tag_stack = [doc]

          node.children.each do |child_node|
            case child_node.type
              when :tag
                closing, _, _, self_closing = child_node.children

                if closing
                  tag_stack.pop.tap do |last_tag|
                    last_tag.closed = true
                  end
                else
                  tag = visit_tag(child_node)
                  tag_stack.last.children << tag

                  if self_closing
                    tag.self_closed = true
                  else
                    tag_stack.push(tag)
                  end
                end
              else
                tag_stack.last.children.concat(
                  Array(visit_non_tag(child_node))
                )
            end
          end
        end
      end

      def visit_non_tag(node)
        if node.is_a?(String)
          return TextNode.new(node)
        end

        case node.type
          when :text
            visit_text(node)
          when :erb
            visit_erb(node)
          when :quote
            visit_quote(node)
        end
      end

      def visit_tag(node)
        _, name_node, attrs_node = node.children
        name = visit_tag_name(name_node)
        attrs = visit_attrs(attrs_node) if attrs_node
        TagNode.new(name, attrs || {})
      end

      def visit_tag_name(node)
        node.children[0]
      end

      def visit_attrs(node)
        node.children.each_with_object({}) do |attr_node, memo|
          name_node, _eq, value_node = attr_node.children
          name = name_node.children[0]
          memo[name] = value_node.children.map { |n| visit_non_tag(n) }
        end
      end

      def visit_erb(node)
        indicator, _, code = node.children

        if indicator
          RubyEchoNode.new(code.children.first)
        else
          RubyNode.new(code.children.first)
        end
      end

      def visit_text(node)
        node.children.map do |child_node|
          visit_non_tag(child_node)
        end
      end

      def visit_quote(node)
        QuoteNode.new(node.children.first)
      end
    end
  end
end
