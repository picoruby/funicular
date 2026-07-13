class GreetingComponent < Funicular::Component
  def initialize_state
    { title: "Default Title", items: [] }
  end

  def render(h)
    h.div(class: "greeting") do |hh|
      hh.h1 { state[:title] }
      hh.ul do |hhh|
        state[:items].each do |item|
          hhh.li(key: item["id"]) { item["name"] }
        end
      end
    end
  end
end
