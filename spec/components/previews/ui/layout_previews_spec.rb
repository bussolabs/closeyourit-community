# frozen_string_literal: true

require "rails_helper"

# CYRA-748 — le preview dei mattoni di impaginazione: il catalogo Lookbook è l'unico posto in cui si
# guardano affiancati, e una preview che solleva non la vede nessuno finché non si apre quella
# pagina. Qui si rende ogni esempio e si pretende che non esploda.
RSpec.describe "Le preview dei mattoni di impaginazione", type: :component do
  {
    Ui::StackComponentPreview => Ui::StackComponent,
    Ui::GridComponentPreview => Ui::GridComponent,
    Ui::SectionComponentPreview => Ui::SectionComponent,
    Ui::DescriptionListComponentPreview => Ui::DescriptionListComponent
  }.each do |preview, componente|
    describe componente.name do
      let(:described_class) { componente }

      preview.examples.each do |example|
        it "rende l'esempio '#{example}' senza errori" do
          expect { render_preview(example, from: preview) }.not_to raise_error
        end
      end
    end
  end
end
