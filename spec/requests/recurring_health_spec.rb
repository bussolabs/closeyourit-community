# frozen_string_literal: true

require "rails_helper"

# CYRA-752 · Lo staging esegue i job dentro Puma e il contenitore si addormenta quando nessuno lo
# usa: i giri ricorrenti non partivano mai e una regressione su di essi si vedeva solo in produzione.
# Il rilascio ora tiene sveglio lo staging e interroga QUESTO endpoint: se i giri non ripartono, il
# rilascio diventa rosso invece di passare in silenzio.
RSpec.describe "GET /up/recurring", type: :request do
  context "quando lo Scheduler batte e ha accodato di recente" do
    before { allow(Ops::RecurringSchedule).to receive(:status).and_return(:up) }

    it "risponde 200 dicendo che i giri ricorrenti girano" do
      get "/up/recurring"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("recurring" => "up")
    end

    # L'età serve a chi interroga da fuori: senza, un accodamento rimasto lì da prima del risveglio
    # è indistinguibile da uno appena fatto, e la sveglia post-rilascio proverebbe il nulla.
    it "riporta l'ultimo accodamento, la sua età e quanti giri sono registrati" do
      allow(Ops::RecurringSchedule).to receive_messages(
        last_run_at: Time.utc(2026, 9, 2, 12), last_run_age_seconds: 37, registered_count: 42
      )

      get "/up/recurring"

      expect(response.parsed_body).to include(
        "last_run_at" => Time.utc(2026, 9, 2, 12).iso8601, "last_run_age_seconds" => 37, "tasks" => 42
      )
    end
  end

  context "quando nessuno Scheduler è vivo" do
    before { allow(Ops::RecurringSchedule).to receive(:status).and_return(:down) }

    it "risponde 503, così il rilascio fallisce" do
      get "/up/recurring"

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body).to include("recurring" => "down")
    end
  end

  context "quando lo Scheduler è vivo ma non accoda più" do
    before { allow(Ops::RecurringSchedule).to receive(:status).and_return(:stale) }

    # È il guasto che l'heartbeat da solo non vede (CYRA-299 per il motore dei job): vivo e inutile.
    it "risponde 503" do
      get "/up/recurring"

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body).to include("recurring" => "stale")
    end
  end

  context "quando l'ambiente non dichiara giri ricorrenti" do
    before { allow(Ops::RecurringSchedule).to receive(:status).and_return(:disabled) }

    # Spento di proposito ≠ rotto: un'installazione senza giri ricorrenti deve poter rilasciare.
    it "risponde 200 dicendo che non c'è niente da far girare" do
      get "/up/recurring"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("recurring" => "disabled")
    end
  end

  it "è pubblico: non chiede di autenticarsi, come /up e /up/workers" do
    get "/up/recurring"

    expect(response).not_to have_http_status(:found)
    expect(response).not_to have_http_status(:unauthorized)
  end
end
