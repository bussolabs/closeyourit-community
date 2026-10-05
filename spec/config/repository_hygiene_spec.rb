# frozen_string_literal: true

require "rails_helper"
require "open3"

# CYRA-278 — I `.DS_Store` sono file che macOS scrive da solo in ogni cartella che qualcuno apre nel
# Finder: nessuno li aggiunge apposta, entrano con un `git add .` distratto e da lì tornano a ogni
# commit. Erano tracciati in due punti del repository. `.gitignore` da solo non basta a impedirlo
# domani, perché ignora solo ciò che non è GIÀ tracciato: serve qualcuno che se ne accorga, ed è
# questo spec.
RSpec.describe "Igiene del repository" do
  it "ignora i .DS_Store ovunque, non solo in radice" do
    expect(Rails.root.join(".gitignore").read).to match(/^\.DS_Store$/)
  end

  it "non tiene sotto controllo di versione nessun .DS_Store" do
    tracked, status = Open3.capture2("git", "ls-files", "-z", chdir: Rails.root.to_s)
    skip("git non disponibile: l'unica prova possibile è il .gitignore") unless status.success?

    junk = tracked.split("\0").select { |path| File.basename(path) == ".DS_Store" }
    expect(junk).to be_empty, "file di sistema tracciati: #{junk.join(', ')}"
  end
end
