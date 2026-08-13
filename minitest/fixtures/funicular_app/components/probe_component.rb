# Reads both props and state so SSR.render_component tests can assert
# each channel is wired through. Not routed on purpose: rendering it
# is only possible through the single-component entry point.
class ProbeComponent < Funicular::Component
  def initialize_state
    { note: "default note" }
  end

  def render
    div(class: "probe") do
      h2 { props[:label].to_s }
      p { state[:note] }
    end
  end
end
