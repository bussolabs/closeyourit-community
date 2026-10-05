# frozen_string_literal: true

require "rails_helper"

# CYRA-740 — chi può fare cosa, estratto da OrganizationContext. Qui si esercitano in isolamento i
# rami che un request spec non raggiunge: le due guardie con Current vuoto (safe-nav nel log del
# rifiuto), che è lo stato in cui si trova una richiesta arrivata senza contesto.
RSpec.describe PermissionGates do
  subject(:controller) do
    ctrl = Member::MembersController.new
    ctrl.set_request!(ActionDispatch::TestRequest.create)
    ctrl.set_response!(Member::MembersController.make_response!(ctrl.request))
    ctrl
  end

  after { Current.reset }

  describe "#require_permission!" do
    it "ritorna senza redirect quando il permesso è concesso" do
      allow(controller).to receive(:can?).and_return(true)
      controller.send(:require_permission!, "members.view")
      expect(controller.response.location).to be_nil
    end

    it "logga e reindirizza quando negato, con account/org presenti (safe-nav then)" do
      Current.account = create(:account)
      Current.organization = create(:organization)
      allow(controller).to receive(:can?).and_return(false)
      controller.send(:require_permission!, "members.view")
      expect(controller.response).to be_redirect
    end

    it "logga e reindirizza quando negato con Current vuoto (safe-nav else su account/org)" do
      Current.account = nil
      Current.organization = nil
      allow(controller).to receive(:can?).and_return(false)
      controller.send(:require_permission!, "members.view")
      expect(controller.response).to be_redirect
    end
  end

  describe "#require_actor_privileged!" do
    it "ritorna senza redirect quando l'attore è privilegiato" do
      allow(controller).to receive(:actor_privileged?).and_return(true)
      controller.send(:require_actor_privileged!)
      expect(controller.response.location).to be_nil
    end

    it "logga e reindirizza quando non privilegiato con Current vuoto (safe-nav else)" do
      Current.account = nil
      Current.organization = nil
      allow(controller).to receive(:actor_privileged?).and_return(false)
      controller.send(:require_actor_privileged!)
      expect(controller.response).to be_redirect
    end
  end
end
