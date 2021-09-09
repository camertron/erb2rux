require 'spec_helper'

describe Erb2Rux::Transformer do
  def transform(str)
    described_class.transform(str)
  end

  it 'handles a literal string' do
    expect(transform('foo')).to eq('"foo"')
  end

  it 'handles a single variable' do
    expect(transform('<%= foo %>')).to eq('foo')
  end

  it 'concatenates strings and code' do
    expect(transform('foo <%= bar %>')).to eq('"foo"  + bar')
  end

  it 'handles a simple if statement' do
    result = transform(<<~ERB).strip
      <% if foo %>
        bar
      <% else %>
        <%= baz %>
      <% end %>
    ERB

    expect(result).to eq(<<~RUX.strip)
      if foo
        "bar"
      else
        baz
      end
    RUX
  end

  it 'wraps code in curlies' do
    expect(transform('<a><%= foo %></a>')).to eq('<a>{foo}</a>')
  end

  it 'wraps control structures in curlies' do
    result = transform(<<~ERB).strip
      <a>
        <% if foo %>
          bar
        <% else %>
          <%= baz %>
        <% end %>
      </a>
    ERB

    expect(result).to eq(<<~RUX.strip)
      <a>
        {if foo
          "bar"
        else
          baz
        end}
      </a>
    RUX
  end

  it 'handles component renders' do
    result = transform(<<~ERB).strip
      <%= render(FooComponent.new) %>
    ERB

    expect(result).to eq('<FooComponent />')
  end

  it 'handles component renders with arguments' do
    result = transform(<<~ERB).strip
      <%= render(FooComponent.new(bar: 'baz')) %>
    ERB

    expect(result).to eq('<FooComponent bar={"baz"} />')
  end

  it 'handles component renders with empty blocks' do
    result = transform(<<~ERB).strip
      <%= render(FooComponent.new(bar: 'baz')) do %>
      <% end %>
    ERB

    expect(result).to eq(<<~RUX.strip)
      <FooComponent bar={"baz"}>
      </FooComponent>
    RUX
  end

  it 'handles component renders with blocks that contain strings' do
    result = transform(<<~ERB).strip
      <%= render(FooComponent.new(bar: 'baz')) do %>
        foobar
      <% end %>
    ERB

    expect(result).to eq(<<~RUX.strip)
      <FooComponent bar={"baz"}>
        {"foobar"}
      </FooComponent>
    RUX
  end

  it 'handles component renders with blocks that contain code' do
    result = transform(<<~ERB).strip
      <%= render(FooComponent.new(bar: 'baz')) do %>
        <%= foobar %>
      <% end %>
    ERB

    expect(result).to eq(<<~RUX.strip)
      <FooComponent bar={"baz"}>
        {foobar}
      </FooComponent>
    RUX
  end

  it 'handles component renders with blocks that contain strings and code' do
    result = transform(<<~ERB).strip
      <%= render(FooComponent.new(bar: 'baz')) do %>
        <%= foobar %> foobaz
      <% end %>
    ERB

    expect(result).to eq(<<~RUX.strip)
      <FooComponent bar={"baz"}>
        {foobar +  "foobaz"}
      </FooComponent>
    RUX
  end

  it 'handles component renders with blocks that have a block arg' do
    result = transform(<<~ERB).strip
      <%= render(FooComponent.new(bar: 'baz')) do |component| %>
      <% end %>
    ERB

    expect(result).to eq(<<~RUX.strip)
      <FooComponent bar={"baz"} as={"component"}>
      </FooComponent>
    RUX
  end

  it 'handles component renders with blocks that have a block arg and code' do
    result = transform(<<~ERB).strip
      <%= render(FooComponent.new(bar: 'baz')) do |component| %>
        <% component.sidebar do %>
        <% end %>
      <% end %>
    ERB

    expect(result).to eq(<<~RUX.strip)
      <FooComponent bar={"baz"} as={"component"}>
        {component.sidebar do
        end}
      </FooComponent>
    RUX
  end

  it 'handles component renders with blocks that have a block arg and multiple expressions' do
    result = transform(<<~ERB).strip
      <%= render(FooComponent.new(bar: 'baz')) do |component| %>
        <% component.sidebar do %>
        <% end %>
        <% component.main do %>
        <% end %>
      <% end %>
    ERB

    expect(result).to eq(<<~RUX.strip)
      <FooComponent bar={"baz"} as={"component"}>
        {component.sidebar do
        end
        component.main do
        end}
      </FooComponent>
    RUX
  end

  it 'handles nesting other components inside blocks' do
    result = transform(<<~ERB).strip
      <%= render(FooComponent.new(bar: 'baz')) do |component| %>
        <% component.sidebar do %>
          <%= render(SidebarComponent.new) %>
        <% end %>
        <% component.main do %>
          <%= render(MainComponent.new) %>
        <% end %>
      <% end %>
    ERB

    expect(result).to eq(<<~RUX.strip)
      <FooComponent bar={"baz"} as={"component"}>
        {component.sidebar do
          <SidebarComponent />
        end
        component.main do
          <MainComponent />
        end}
      </FooComponent>
    RUX
  end

  it 'handles nesting other components with arguments inside blocks' do
    result = transform(<<~ERB).strip
      <%= render(FooComponent.new(bar: 'baz')) do |component| %>
        <% component.sidebar do %>
          <%= render(SidebarComponent.new(bar: 'baz')) %>
        <% end %>
        <% component.main do %>
          <%= render(MainComponent.new(bar: 'baz')) %>
        <% end %>
      <% end %>
    ERB

    expect(result).to eq(<<~RUX.strip)
      <FooComponent bar={"baz"} as={"component"}>
        {component.sidebar do
          <SidebarComponent bar={"baz"} />
        end
        component.main do
          <MainComponent bar={"baz"} />
        end}
      </FooComponent>
    RUX
  end

  it 'handles nesting other components with blocks' do
    result = transform(<<~ERB).strip
      <%= render(FooComponent.new(bar: 'baz')) do |component| %>
        <% component.sidebar do %>
          <%= render(SidebarComponent.new(bar: 'baz')) do %>
          <% end %>
        <% end %>
        <% component.main do %>
          <%= render(MainComponent.new(bar: 'baz')) do %>
          <% end %>
        <% end %>
      <% end %>
    ERB

    expect(result).to eq(<<~RUX.strip)
      <FooComponent bar={"baz"} as={"component"}>
        {component.sidebar do
          <SidebarComponent bar={"baz"}>
          </SidebarComponent>
        end
        component.main do
          <MainComponent bar={"baz"}>
          </MainComponent>
        end}
      </FooComponent>
    RUX
  end
end
