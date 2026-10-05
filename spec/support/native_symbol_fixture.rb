# frozen_string_literal: true

module NativeSymbolFixture
  def native_fixture
    paths = ENV.values_at("NATIVE_SYMBOL_OBJECT", "NATIVE_SYMBOL_PROOF")
    skip "Set the native object, proof and isolated processor environment variables" if paths.any?(&:blank?) || ENV["NATIVE_SYMBOL_PROCESSOR_URL"].blank?
    @native_fixture ||= JSON.parse(File.read(paths.last)).fetch("consumer")
  end

  def native_bytes
    native_fixture
    File.binread(ENV.fetch("NATIVE_SYMBOL_OBJECT"))
  end

  def upload_native(project, account = nil)
    Artifacts::NativeSymbols::Upload.call(project: project, account: account, metadata: native_fixture.fetch("symbols"), object_base64: Base64.strict_encode64(native_bytes)).artifact
  end
end

RSpec.configure { |config| config.include NativeSymbolFixture }
