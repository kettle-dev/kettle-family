# frozen_string_literal: true

RSpec.describe Kettle::Family::Concurrency do
  describe ".wave_jobs" do
    it "uses half the available CPUs when no outer width is requested" do
      expect(described_class.wave_jobs(requested: nil, item_count: 20, cpu_count: 22)).to eq(11)
      expect(described_class.wave_jobs(requested: nil, item_count: 20, cpu_count: 8)).to eq(4)
    end

    it "honors an explicit outer width within the available work" do
      expect(described_class.wave_jobs(requested: 6, item_count: 20, cpu_count: 8)).to eq(6)
      expect(described_class.wave_jobs(requested: 99, item_count: 3, cpu_count: 8)).to eq(3)
    end

    it "does not allocate workers when there is no work" do
      expect(described_class.wave_jobs(requested: nil, item_count: 0, cpu_count: 8)).to eq(0)
    end
  end

  describe ".internal_worker_limit" do
    it "divides CPUs left after the active wave across its members" do
      expect(described_class.internal_worker_limit(wave_jobs: 6, cpu_count: 22)).to eq(2)
      expect(described_class.internal_worker_limit(wave_jobs: 4, cpu_count: 8)).to eq(1)
    end

    it "caps a single member's additional workers at half the available CPUs" do
      expect(described_class.internal_worker_limit(wave_jobs: 1, cpu_count: 22)).to eq(11)
      expect(described_class.internal_worker_limit(wave_jobs: 1, cpu_count: 8)).to eq(4)
    end

    it "requires a positive outer wave width" do
      expect do
        described_class.internal_worker_limit(wave_jobs: 0, cpu_count: 8)
      end.to raise_error(ArgumentError, /positive/)
    end
  end

  describe ".test_process_ceiling" do
    it "includes the member's primary process when sharing remaining CPUs" do
      expect(described_class.test_process_ceiling(wave_jobs: 6, cpu_count: 22)).to eq(3)
      expect(described_class.test_process_ceiling(wave_jobs: 4, cpu_count: 8)).to eq(2)
    end

    it "caps a single member test run at half the detected CPUs" do
      expect(described_class.test_process_ceiling(wave_jobs: 1, cpu_count: 22)).to eq(11)
      expect(described_class.test_process_ceiling(wave_jobs: 1, cpu_count: 8)).to eq(4)
    end
  end
end
