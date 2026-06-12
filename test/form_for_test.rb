class FormForTest < Picotest::Test
  class FormComponent < Funicular::Component
    attr_reader :submitted

    def initialize_state
      { comment: { body: "" } }
    end

    def handle_submit(data)
      @submitted = data
    end

    def render
      form_for(:comment, on_submit: :handle_submit) do |f|
        f.textarea(:body)
        f.submit("Post")
      end
    end
  end

  class SubmitEvent
    attr_reader :target

    def initialize(target)
      @target = target
      @prevented = false
    end

    def preventDefault
      @prevented = true
    end

    def prevented?
      @prevented
    end

    def [](key)
      key == :target ? @target : nil
    end
  end

  class FormElement
    def initialize(elements)
      @elements = Elements.new(elements)
    end

    def [](key)
      key == :elements ? @elements : nil
    end
  end

  class Elements
    def initialize(elements)
      @elements = elements
    end

    def [](key)
      return @elements.length if key == :length

      @elements[key]
    end
  end

  class Field
    def initialize(attrs)
      @attrs = attrs
    end

    def [](key)
      @attrs[key]
    end
  end

  def test_form_for_submits_current_dom_values
    component = FormComponent.new
    vnode = component.build_vdom
    event = SubmitEvent.new(
      FormElement.new([
        Field.new(name: "body", type: "textarea", value: "fresh")
      ])
    )

    vnode.props[:onsubmit].call(event)

    assert_equal(true, event.prevented?)
    assert_equal({ body: "fresh" }, component.submitted)
  end

  def test_form_builder_fields_include_names
    component = FormComponent.new
    vnode = component.build_vdom
    textarea = vnode.children[0].children[0]

    assert_equal("body", textarea.props[:name])
  end
end
