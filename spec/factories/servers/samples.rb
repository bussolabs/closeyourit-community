# frozen_string_literal: true

FactoryBot.define do
  factory :server_sample, class: "Servers::Sample" do
    host factory: :server_host
    organization { host.organization }
    recorded_at { Time.current }
    cpu_pct { 12.5 }
    mem_pct { 40.0 }
    disk_pct { 55.0 }
    load_1 { 0.42 }
    load_5 { 0.38 }
    load_15 { 0.30 }
    net_sent_bytes { 1024 }
    net_recv_bytes { 2048 }
    temp_max { 48.5 }
    payload { {} }
  end

  factory :server_container_sample, class: "Servers::ContainerSample" do
    host factory: :server_host
    recorded_at { Time.current }
    sequence(:name) { |n| "container-#{n}" }
    image { "nginx:latest" }
    status { "running" }
    health { :none }
    cpu_pct { 1.5 }
    mem_bytes { 64 * 1024 * 1024 }
    net_sent_bytes { 100 }
    net_recv_bytes { 200 }
  end
end
