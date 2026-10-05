# frozen_string_literal: true

require "rails_helper"
require "rubygems/package"
require "zlib"

# Locations stayed empty in production: the GeoLite2 file was never downloaded (CYRA-914 P10).
RSpec.describe Analytics::DownloadGeoDatabase do
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "GeoLite2-Country.mmdb") }
  let(:url) { %r{\Ahttps://download\.maxmind\.com/app/geoip_download\?edition_id=GeoLite2-Country&license_key=lk-test&suffix=tar\.gz\z} }

  after { FileUtils.remove_entry(dir) }

  # The archive MaxMind serves: a dated folder with the database inside.
  def archive(content)
    tar = StringIO.new
    Gem::Package::TarWriter.new(tar) do |writer|
      writer.add_file("GeoLite2-Country_20261001/GeoLite2-Country.mmdb", 0o644) { |file| file.write(content) }
      writer.add_file("GeoLite2-Country_20261001/LICENSE.txt", 0o644) { |file| file.write("license") }
    end
    gzip = StringIO.new
    Zlib::GzipWriter.wrap(gzip) { |writer| writer.write(tar.string) }
    gzip.string
  end

  it "does nothing without a license key, so an install without MaxMind behaves as before" do
    result = described_class.call(license_key: nil, path: path)

    expect(result).not_to be_ok
    expect(File.exist?(path)).to be(false)
    expect(WebMock).not_to have_requested(:get, /maxmind/)
  end

  it "downloads the country database into place" do
    stub_request(:get, url).to_return(status: 200, body: archive("mmdb-bytes"))

    expect(described_class.call(license_key: "lk-test", path: path)).to be_ok
    expect(File.binread(path)).to eq("mmdb-bytes")
  end

  it "leaves a file younger than a week alone" do
    File.binwrite(path, "recent")

    expect(described_class.call(license_key: "lk-test", path: path)).to be_ok
    expect(WebMock).not_to have_requested(:get, /maxmind/)
  end

  it "keeps the old file when the download fails" do
    File.binwrite(path, "old")
    FileUtils.touch(path, mtime: 8.days.ago.to_time)
    stub_request(:get, url).to_return(status: 401)

    expect(described_class.call(license_key: "lk-test", path: path)).not_to be_ok
    expect(File.binread(path)).to eq("old")
  end
end
