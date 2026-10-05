# frozen_string_literal: true

require "rails_helper"

RSpec.describe AuthorizationHelper, type: :helper do
  describe "#authorization_area_summary" do
    it "elenca le aree col loro nome, nell'ordine del catalogo" do
      riepilogo = helper.authorization_area_summary(%w[members.view tickets.edit])

      expect(riepilogo).to eq("#{I18n.t('authorization.areas.tickets')}, #{I18n.t('authorization.areas.people')}")
    end

    # CYRA-574 — il riepilogo aveva un testo di ripiego che stampava il nome interno dell'area:
    # nell'elenco dei ruoli usciva «knowledge» minuscolo in mezzo a nomi italiani, e la stessa area
    # mostrava il segnaposto di i18n nella pagina dei permessi, dove il ripiego non c'era. Un buco
    # mascherato in un posto e visibile nell'altro non si scopre guardando la pagina che regge.
    it "nomina anche le aree aggiunte per ultime, senza ricadere sull'identificatore interno" do
      riepilogo = helper.authorization_area_summary(%w[knowledge.edit chat.moderate])

      expect(riepilogo).to eq("#{I18n.t('authorization.areas.knowledge')}, #{I18n.t('authorization.areas.chat')}")
      expect(riepilogo).not_to include("knowledge", "chat")
    end

    it "oltre le prime tre conta le altre invece di allungare la cella" do
      riepilogo = helper.authorization_area_summary(%w[tickets.edit ideas.edit errors.triage projects.edit members.view])

      expect(riepilogo).to end_with(" +2")
    end

    it "senza permessi dice che non ce n'è nessuno" do
      expect(helper.authorization_area_summary([])).to eq(I18n.t("member.roles.no_permissions"))
    end
  end
end
