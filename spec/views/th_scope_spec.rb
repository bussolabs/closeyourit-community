# frozen_string_literal: true

require "rails_helper"

# CYRA-685 — 123 intestazioni di colonna scritte a mano non dichiaravano a quale colonna
# appartengono: chi usa un lettore di schermo sentiva i valori senza contesto. Il componente lo fa
# da sé (CYRA-670); questo guard tiene in riga i <th> scritti a mano, presenti e futuri.
RSpec.describe "Viste — ogni <th> dichiara il proprio scope" do
  it "nessun <th> senza scope nelle viste" do
    offending = Dir[Rails.root.join("app/views/**/*.erb")].flat_map do |file|
      File.read(file).scan(/<th (?![^>]*scope=)[^>]*/).map do |tag|
        "#{Pathname(file).relative_path_from(Rails.root)}: #{tag[0, 60]}"
      end
    end

    expect(offending).to be_empty, "Aggiungi scope=\"col\" (o \"row\"):\n#{offending.join("\n")}"
  end
end
