# frozen_string_literal: true

require "rails_helper"

RSpec.describe Seo::NotifyIssues, type: :service do
  let(:site) { create(:seo_site) }

  def issue(severity:, check_key: "missing_h1")
    create(:seo_issue, site:, check_key:, severity:, page: create(:seo_page, site:))
  end

  it "avvisa sui rilievi gravi" do
    critical = issue(severity: :critical, check_key: "noindex")

    expect { described_class.call(issues: [ critical ]) }
      .to have_enqueued_job(Alerting::EvaluateJob)
      .with(hash_including(event_type: "seo_issue_new", subject_type: "Seo::Issue", subject_id: critical.id))
  end

  it "tace sui rilievi minori: un cockpit che avvisa per tutto insegna a ignorarlo" do
    minori = [ issue(severity: :low, check_key: "title_too_long"), issue(severity: :medium, check_key: "thin_content") ]

    expect { described_class.call(issues: minori) }.not_to have_enqueued_job(Alerting::EvaluateJob)
  end

  it "porta con sé progetto e ambiente del sito, che sono ciò su cui le regole filtrano" do
    grave = issue(severity: :high)

    described_class.call(issues: [ grave ])

    expect(Alerting::EvaluateJob).to have_been_enqueued.with(
      hash_including(project_id: site.project_id, environment_id: site.environment_id)
    )
  end

  it "conta quanti avvisi ha davvero accodato" do
    result = described_class.call(issues: [ issue(severity: :critical, check_key: "noindex"),
                                            issue(severity: :low, check_key: "title_too_long") ])

    expect(result.value).to eq(1)
  end
end
