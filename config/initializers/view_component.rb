# frozen_string_literal: true

# ViewComponent: preview (Lookbook) in spec/components/previews, mai in produzione.
# Vedi rules/component-catalogs.md.
Rails.application.config.view_component.tap do |vc|
  preview_dir = Rails.root.join("spec/components/previews").to_s
  vc.previews.paths ||= []
  vc.previews.paths << preview_dir unless vc.previews.paths.include?(preview_dir)
  vc.previews.enabled = !Rails.env.production?
  vc.previews.default_layout = "component_preview"
end
