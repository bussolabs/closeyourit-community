# frozen_string_literal: true

require "rails_helper"

RSpec.describe TicketsHelper, type: :helper do
  describe "#ticket_kind_color" do
    it { expect(helper.ticket_kind_color("bug")).to eq(:red) }
    it { expect(helper.ticket_kind_color("story")).to eq(:violet) }
    it { expect(helper.ticket_kind_color("task")).to eq(:sky) }
    it { expect(helper.ticket_kind_color("epic")).to eq(:amber) }
    it("valore ignoto → gray") { expect(helper.ticket_kind_color("boh")).to eq(:gray) }
  end

  # CYRA-392 (rivede CYRA-65) — "creato il <data>" sempre, con "in questo stato da <tempo>" solo sui
  # ticket non ancora conclusi. Il vecchio "aperto da X" contava i giorni anche su un ticket chiuso,
  # mostrando un tempo falso.
  describe "#ticket_created_line" do
    around { |example| I18n.with_locale(:it) { example.run } }

    # Doppio: l'helper legge created_at, status.category_done? e current_status_since.
    def ticket_double(created_at:, done:, status_since: created_at)
      status = instance_double(Types::TicketStatus, category_done?: done)
      instance_double(Ticketing::Ticket, created_at: created_at, status: status, current_status_since: status_since)
    end

    it "mostra sempre 'creato il <data>'" do
      freeze_time do
        result = helper.ticket_created_line(ticket_double(created_at: 10.days.ago, done: false))

        expect(result).to include("creato il")
        expect(result).to include(helper.l(10.days.ago, format: :long))
      end
    end

    it "sui ticket non conclusi aggiunge da quanto sono nello stato corrente" do
      freeze_time do
        result = helper.ticket_created_line(ticket_double(created_at: 10.days.ago, done: false, status_since: 2.days.ago))

        expect(result).to include("in questo stato da")
        expect(result).to include("2 giorni") # datetime localizzato (non "2 days")
      end
    end

    it "sui ticket conclusi NON mostra alcun conteggio di permanenza" do
      freeze_time do
        result = helper.ticket_created_line(ticket_double(created_at: 10.days.ago, done: true))

        expect(result).to include("creato il")
        expect(result).not_to include("in questo stato")
      end
    end
  end

  describe "#board_card_title (K13)" do
    it "marks every searched word, ignoring case" do
      expect(helper.board_card_title("Webhook retries duplicate webhook orders", "webhook"))
        .to eq('<mark class="rounded-sm bg-amber-100 dark:bg-amber-500/25 px-0.5 text-inherit">Webhook</mark> retries duplicate ' \
               '<mark class="rounded-sm bg-amber-100 dark:bg-amber-500/25 px-0.5 text-inherit">webhook</mark> orders')
    end

    it "keeps markup in the title as plain text" do
      html = helper.board_card_title("<b>Bold</b> <img src=x onerror=alert(1)> webhook", "webhook")

      expect(html).to start_with("&lt;b&gt;Bold&lt;/b&gt; &lt;img src=x onerror=alert(1)&gt; <mark")
      expect(html).to be_html_safe
    end

    it "returns the title untouched without a search" do
      expect(helper.board_card_title("<b>x</b>", nil)).to eq("<b>x</b>")
    end
  end
end
