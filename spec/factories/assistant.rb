# frozen_string_literal: true

FactoryBot.define do
  # Default = l'assistente del sito (kind help), che è quello che le crea da sempre. Il trait copre
  # l'altro: stessa tabella, regole opposte (legge i dati invece di indicare le pagine).
  factory :assistant_conversation, class: "Assistant::Conversation" do
    association :account
    association :organization

    trait :tools do
      kind { :tools }
    end
  end

  # Default = messaggio dell'utente (già completo: non fa streaming). I trait coprono la risposta
  # dell'assistente nelle sue fasi (streaming vuota → complete/failed).
  factory :assistant_message, class: "Assistant::Message" do
    association :conversation, factory: :assistant_conversation
    role { :user }
    status { :complete }
    content { "Come segnalo un bug?" }

    # Integrità tenant: org denormalizzata dalla conversazione (come chat_message).
    after(:build) do |message|
      message.organization ||= message.conversation&.organization
    end

    trait :assistant_streaming do
      role { :assistant }
      status { :streaming }
      content { nil }
    end

    trait :assistant_reply do
      role { :assistant }
      status { :complete }
      content { "Per segnalare un bug vai su Ticket (/member/tickets)." }
    end

    trait :failed do
      role { :assistant }
      status { :failed }
      content { nil }
      error_code { "R502-LLM-001" }
    end
  end
end
