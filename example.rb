require 'erb2rux'
require 'pry-byebug'

template = <<~ERB
<% if foo %>
  bar <%= baz %>
<% else %>
  baz
<% end %>
<h1>
  <br/>
  <p class="foo">
    <span>
      <% if foo %>
        <%= bar %>
      <% else %>
        baz
      <% end %>
      <%= render(FooComponent.new(foo: "bar")) do |component| %>
        <% component.item do %>
          <a href="foo.com"><%= "Link" %></a>
        <% end %>
      <% end %>
    </span>
  </p>
</h1>
ERB

puts Erb2Rux::Transformer.transform(template)
