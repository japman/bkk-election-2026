require "rails_helper"

RSpec.describe Drive::FolderClient do
  let(:fixture) { Rails.root.join("spec/fixtures/drive/folder_list.html").read }

  it "lists files (id + name) from a public folder" do
    stub_request(:get, "https://drive.google.com/embeddedfolderview?id=FOLDER123")
      .to_return(status: 200, body: fixture)
    files = described_class.list("FOLDER123")
    expect(files).to contain_exactly(
      { id: "FILEID_AAA", name: "BKK-007.png" },
      { id: "FILEID_BBB", name: ".DS_Store" }
    )
  end

  it "downloads file bytes" do
    stub_request(:get, "https://drive.google.com/uc?export=download&id=FILE9")
      .to_return(status: 200, body: "\x89PNG-bytes")
    expect(described_class.download("FILE9")).to eq("\x89PNG-bytes")
  end

  it "raises Error on a non-2xx list response" do
    stub_request(:get, "https://drive.google.com/embeddedfolderview?id=BAD")
      .to_return(status: 404, body: "nope")
    expect { described_class.list("BAD") }.to raise_error(Drive::FolderClient::Error, /404/)
  end
end
