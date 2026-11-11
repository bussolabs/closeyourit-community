# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "frame_missing"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
pin_all_from "app/javascript/lib", under: "lib"
# Loaded only by the dynamic import in the replay player: never modulepreloaded on every page (CYRA-888).
pin "rrweb-player", preload: false # @2.1.1 (bundle esbuild locale, vedi header del file vendorizzato)
# Loaded only by the dynamic import of the project Map tab (CYRA-1071).
pin "cytoscape", preload: false # @3.30.2
# Loaded only by the dynamic import of the Coworkers office (CYRA-1283).
pin "three", preload: false # @0.160.0
pin "three/examples/jsm/controls/OrbitControls.js", to: "three--examples--jsm--controls--OrbitControls.js.js", preload: false # @0.160.0
pin "coworker_office/scene", to: "coworker_office/scene.js", preload: false
pin "coworker_office/mascots", to: "coworker_office/mascots.js", preload: false
pin "coworker_office/garden", to: "coworker_office/garden.js", preload: false
pin "coworker_office/atmosphere", to: "coworker_office/atmosphere.js", preload: false
pin "coworker_office/batching", to: "coworker_office/batching.js", preload: false
pin "coworker_office/daylight", to: "coworker_office/daylight.js", preload: false
pin "coworker_office/world", to: "coworker_office/world.js", preload: false
pin "coworker_office/rooms", to: "coworker_office/rooms.js", preload: false
pin "coworker_office/details", to: "coworker_office/details.js", preload: false
