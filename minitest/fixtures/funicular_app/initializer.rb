Funicular.start(container: "app") do |router|
  router.get("/greet", to: GreetingComponent, as: "greet")
  router.get("/greet/:id", to: GreetingComponent, as: "greet_item")
  router.set_default("/greet")
end
