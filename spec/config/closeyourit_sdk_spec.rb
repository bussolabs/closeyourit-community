# frozen_string_literal: true

require "rails_helper"

# Guard anti-ricorsione dell'auto-monitoraggio. Regressione del 2026-07-29: Solid Cable su SQLite va
# in lock sotto burst → SQLite3::BusyException in Puma → l'SDK la spedisce alla nostra stessa API →
# l'ingest la persiste E fa broadcast Turbo → il broadcast riscrive sul cable → altro lock. 200.670
# eventi in otto ore, 8,6 GB di payload. Un anello con guadagno > 1 non si ferma da solo: sopravvive
# alla rimozione della causa che l'ha innescato. Questa spec tiene chiusa la porta.
RSpec.describe "SDK CloseYourIt — guard anti-loop" do
  subject(:excluded) { CloseYourIt.configuration.excluded_exceptions }

  it "esclude gli errori di lock del canale realtime" do
    matched = excluded.any? do |matcher|
      matcher.is_a?(Regexp) && matcher.match?("SQLite3::BusyException")
    end

    expect(matched).to be(true)
  end

  # Il caso REALE non è l'eccezione nuda: Rails la incapsula in ActiveRecord::StatementTimeout, che
  # NON ha SQLite3::BusyException fra gli ancestor — se lo porta solo nel messaggio. Per questo il
  # matcher è un Regexp: l'SDK confronta i nomi degli antenati E il messaggio.
  it "copre il wrapper ActiveRecord che l'app riceve davvero" do
    message = "SQLite3::BusyException: database is locked"

    matched = excluded.any? { |m| m.is_a?(Regexp) && m.match?(message) }

    expect(matched).to be(true)
  end

  it "non esclude gli errori applicativi ordinari" do
    matched = excluded.any? do |matcher|
      matcher.is_a?(Regexp) ? matcher.match?("ActiveRecord::RecordInvalid") : matcher == "ActiveRecord::RecordInvalid"
    end

    expect(matched).to be(false)
  end
end
