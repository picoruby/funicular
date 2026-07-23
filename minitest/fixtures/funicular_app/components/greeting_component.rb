class GreetingComponent < Funicular::Component
  def initialize_state
    { title: "Default Title", items: [] }
  end

  def render
    div(class: "greeting") do
      h1 { state[:title] }
      ul do
        state[:items].each do |item|
          li(key: item["id"]) { item["name"] }
        end
      end
    end
  end
end
