# frozen_string_literal: true

require "rails_helper"

# CYRA-323: righe display del notification center — avvisi identici ravvicinati in un gruppo, un
# cambio di testo (peggioramento del conteggio) genera un gruppo nuovo invece di sparire dentro il
# precedente.
RSpec.describe Alerting::NotificationGroup do
  let(:host_1) { create(:server_host) }
  let(:host_2) { create(:server_host) }

  def notification_at(created_at, title: "Contenitore caduto · apps", body: "27 container caduti su apps.",
                       subject: host_1)
    create(:alerting_notification, title: title, body: body, subject: subject, created_at: created_at)
  end

  describe ".group" do
    it "raggruppa avvisi identici ravvicinati in un solo gruppo col conteggio" do
      notifications = [
        notification_at(30.minutes.ago),
        notification_at(45.minutes.ago),
        notification_at(50.minutes.ago)
      ]

      groups = described_class.group(notifications)

      expect(groups.size).to eq(1)
      expect(groups.first.count).to eq(3)
      expect(groups.first.repeated?).to be(true)
    end

    it "un avviso mai ripetuto resta un gruppo singolo, senza badge di ripetizione" do
      groups = described_class.group([ notification_at(10.minutes.ago) ])

      expect(groups.size).to eq(1)
      expect(groups.first.repeated?).to be(false)
    end

    it "un cambio di corpo (peggioramento del conteggio) genera un gruppo nuovo" do
      notifications = [
        notification_at(10.minutes.ago, body: "42 container caduti su apps."),
        notification_at(20.minutes.ago, body: "27 container caduti su apps.")
      ]

      groups = described_class.group(notifications)

      expect(groups.size).to eq(2)
      expect(groups.map(&:repeated?)).to eq([ false, false ])
    end

    it "oltre la finestra di 60 minuti dal più recente del gruppo → gruppo nuovo" do
      notifications = [
        notification_at(5.minutes.ago),
        notification_at(90.minutes.ago)
      ]

      groups = described_class.group(notifications)

      expect(groups.size).to eq(2)
    end

    it "soggetti diversi non si raggruppano anche con lo stesso testo" do
      notifications = [
        notification_at(5.minutes.ago, subject: host_1),
        notification_at(10.minutes.ago, subject: host_2)
      ]

      groups = described_class.group(notifications)

      expect(groups.size).to eq(2)
    end
  end

  describe "#read?" do
    it "letto solo se TUTTI i membri del gruppo sono letti" do
      read_notification = notification_at(10.minutes.ago).tap { |n| n.update!(read_at: Time.current) }
      unread_notification = notification_at(20.minutes.ago)
      group = described_class.new(read_notification)
      group.add(unread_notification)

      expect(group.read?).to be(false)
    end
  end

  describe "#ids" do
    it "espone gli id di tutti i membri del gruppo" do
      a = notification_at(10.minutes.ago)
      b = notification_at(20.minutes.ago)
      group = described_class.new(a)
      group.add(b)

      expect(group.ids).to contain_exactly(a.id, b.id)
    end
  end
end
