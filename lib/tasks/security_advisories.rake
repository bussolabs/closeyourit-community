# frozen_string_literal: true

# CYRA-1160 — signs the list of insecure community versions. The private key is read from the
# environment, filled by the vault (`cyi run`), and is never written anywhere: docs/security-advisories.md.
#
#   bin/rails security_advisories:keygen
#   cyi run -p CYRA -e production -- bin/rails "security_advisories:sign[advisories.unsigned.json,advisories.json]"
namespace :security_advisories do
  desc "Prints a new key pair: the private half goes into the vault, the public one into App::SelfHosted"
  task keygen: :environment do
    key = RbNaCl::SigningKey.generate
    puts "Private key (vault, ADVISORIES_SIGNING_KEY — never in a file or a commit):"
    puts Base64.strict_encode64(key.to_bytes)
    puts "Public key (App::SelfHosted::ADVISORIES_PUBLIC_KEYS):"
    puts Base64.strict_encode64(key.verify_key.to_bytes)
  end

  desc "Signs the unsigned list with ADVISORIES_SIGNING_KEY, dated now, and checks it as an install would"
  task :sign, %i[input output] => :environment do |_task, args|
    input = args[:input] || abort("usage: security_advisories:sign[unsigned.json,signed.json]")
    output = args[:output] || abort("usage: security_advisories:sign[unsigned.json,signed.json]")
    secret = ENV["ADVISORIES_SIGNING_KEY"].presence || abort("ADVISORIES_SIGNING_KEY is empty: run this through cyi run")

    # Dated at signing time: an install keeps a list only when it is newer than the one it has.
    data = JSON.parse(File.read(input)).merge("issued_at" => Time.current.utc.iso8601)
    payload = JSON.pretty_generate(data)
    key = RbNaCl::SigningKey.new(Base64.strict_decode64(secret))
    envelope = JSON.pretty_generate("payload" => Base64.strict_encode64(payload), "signature" => Base64.strict_encode64(key.sign(payload)))

    # The same check an install runs: a list signed with a key the app does not trust is never published.
    list = Instance::Advisories.verify(envelope)
    File.write(output, "#{envelope}\n")
    puts "Signed #{list.entries.size} advisories, issued at #{list.issued_at.iso8601}: #{output}"
  rescue Instance::Advisories::Invalid => e
    abort "Not signed: #{e.message}. Is the public key of ADVISORIES_SIGNING_KEY in App::SelfHosted::ADVISORIES_PUBLIC_KEYS?"
  end
end
