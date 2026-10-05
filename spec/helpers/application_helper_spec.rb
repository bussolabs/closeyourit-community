# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationHelper, type: :helper do
  describe "#flash_variant" do
    it { expect(helper.flash_variant(:notice)).to eq(:success) }
    it { expect(helper.flash_variant(:alert)).to eq(:danger) }
    it { expect(helper.flash_variant(:warning)).to eq(:warning) }
    it { expect(helper.flash_variant(:qualsiasi)).to eq(:info) }
  end

  describe "#avatar_initials" do
    it { expect(helper.avatar_initials("Ada Lovelace")).to eq("AL") }
    it { expect(helper.avatar_initials("")).to eq("?") }
    it { expect(helper.avatar_initials(nil)).to eq("?") }
  end

  describe "#account_display_name" do
    it "rende il nome quando presente" do
      account = build(:account, name: "Ada Lovelace", email: "ada@example.com")
      expect(helper.account_display_name(account)).to eq("Ada Lovelace")
    end

    it "rende la mail quando il nome è vuoto" do
      account = build(:account, name: "", email: "ada@example.com")
      expect(helper.account_display_name(account)).to eq("ada@example.com")
    end

    it "rende la mail quando il nome è nil" do
      account = build(:account, name: nil, email: "ada@example.com")
      expect(helper.account_display_name(account)).to eq("ada@example.com")
    end

    it "usa Current.account come default" do
      Current.account = build(:account, name: "Grace Hopper")
      expect(helper.account_display_name).to eq("Grace Hopper")
    end

    it "senza account (nil) → nil (nil-safe su name ed email)" do
      expect(helper.account_display_name(nil)).to be_nil
    end
  end

  describe "#activity_actor_name" do
    it "senza evento → nil" do
      expect(helper.activity_actor_name(nil)).to be_nil
    end

    it "con evento → nome dell'attore (via Activity::Presenter, snapshot-first)" do
      project = create(:project)
      event = create(:activity_event, subject: project, organization: project.organization, actor_name: "Marco Rossi")
      expect(helper.activity_actor_name(event)).to eq("Marco Rossi")
    end
  end

  describe "#impersonating?" do
    it "è falso senza sessione" do
      Current.session = nil
      expect(helper.impersonating?).to be_falsey
    end

    it "è vero quando la sessione impersona" do
      Current.session = build(:session, impersonated_account_id: SecureRandom.uuid)
      expect(helper.impersonating?).to be(true)
    end
  end

  # CYRA-568 — il conteggio di una lista compare due volte nella stessa pagina (toolbar e piede):
  # scritto in due modi diversi sembrano due numeri diversi.
  describe "#count_label" do
    it "scrive le migliaia come le scrive la lingua" do
      I18n.with_locale(:it) do
        expect(helper.count_label("member.monitoring.logs.count", 4031)).to eq("4.031 log")
      end
    end

    it "sceglie singolare o plurale sul numero vero, non sulla forma scritta" do
      I18n.with_locale(:en) do
        expect(helper.count_label("member.monitoring.logs.count", 1)).to eq("1 log")
        expect(helper.count_label("member.monitoring.logs.count", 4031)).to eq("4,031 logs")
      end
    end

    it "accetta un totale nil senza rompere la pagina" do
      I18n.with_locale(:it) do
        expect(helper.count_label("member.monitoring.logs.count", nil)).to eq("0 log")
      end
    end

    it "passa le altre interpolazioni alla traduzione" do
      I18n.with_locale(:it) do
        expect(helper.count_label("member.monitoring.occurrences_count", 4031, shown: 100))
          .to eq("4.031 conservate · mostrate 100")
      end
    end
  end

  describe "#ticket_status_badge" do
    it "rende un badge col pallino pulsante se lo status è animato" do
      status = build(:ticket_status, label: "In Progress", color: "indigo", animated: true)
      html = helper.ticket_status_badge(status)
      expect(html).to include("In Progress")
      expect(html).to include("bg-indigo-500")
      expect(html).to include("motion-safe:animate-pulse")
    end

    it "rende il pallino fermo se lo status non è animato" do
      status = build(:ticket_status, label: "Closed", color: "gray", animated: false)
      html = helper.ticket_status_badge(status)
      expect(html).to include("Closed")
      expect(html).not_to include("animate-pulse")
    end
  end
end
