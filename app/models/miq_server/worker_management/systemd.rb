class MiqServer::WorkerManagement::Systemd < MiqServer::WorkerManagement
  def sync_from_system
    self.miq_services         = systemd_services.select { |unit| manageiq_service?(unit) }
    self.miq_services_by_unit = miq_services.index_by { |w| w[:name] }
  end

  def sync_starting_workers
    sync_from_system
    sync_starting_rails_workers
    sync_starting_non_rails_workers

    MiqWorker.find_all_starting.to_a
  end

  def sync_stopping_workers
    sync_from_system
    sync_stopping_rails_workers
    sync_stopping_non_rails_workers

    MiqWorker.find_all_stopping.to_a
  end

  def cleanup_failed_workers
    super

    cleanup_failed_systemd_services
  end

  def cleanup_failed_systemd_services
    service_names = failed_miq_service_names
    return if service_names.empty?

    _log.info("Disabling failed unit files: [#{service_names.join(", ")}]")
    systemd_stop_services(service_names)

    _log.info("Stopping worker records for failed units: [#{service_names.join(", ")}]")
    MiqWorker.find_current_or_starting.where(:system_uid => service_names).each do |w|
      w.update!(:status => MiqWorker::STATUS_STOPPED)
    end
  end

  private

  attr_accessor :miq_services, :miq_services_by_unit

  def sync_stopping_non_rails_workers
    stopping = MiqWorker.find_all_stopping
    stopping.reject(&:rails_worker?).each do |worker|
      # If the worker record is "stopping" and the systemd unit is gone then the
      # worker has successfully exited.
      next if miq_services_by_unit[worker[:system_uid]].present?

      worker.update!(:status => MiqWorker::STATUS_STOPPED)
    end
  end

  def sync_starting_non_rails_workers
    starting = MiqWorker.find_all_starting
    starting.reject(&:rails_worker?).each do |worker|
      systemd_worker = miq_services_by_unit[worker[:system_uid]]
      next if systemd_worker.nil?

      if systemd_worker[:load_state] == "loaded" && systemd_worker[:active_state] == "active" && systemd_worker[:sub_state] == "running"
        worker.update!(:status => MiqWorker::STATUS_STARTED)
      end
    end
  end

  def systemd_manager
    @systemd_manager ||= begin
      require "dbus/systemd"
      DBus::Systemd::Manager.new
    end
  end

  def systemd_stop_services(service_names)
    service_names.each do |service_name|
      systemd_manager.StopUnit(service_name, "replace")
      systemd_manager.ResetFailedUnit(service_name)

      service_settings_dir = systemd_unit_dir.join("#{service_name}.d")
      FileUtils.rm_r(service_settings_dir) if service_settings_dir.exist?
    end

    systemd_manager.DisableUnitFiles(service_names, false)
  end

  def systemd_unit_dir
    Pathname.new("/lib/systemd/system")
  end

  def manageiq_service?(unit)
    manageiq_service_base_names.include?(systemd_service_base_name(unit))
  end

  def manageiq_service_base_names
    @manageiq_service_base_names ||= MiqWorkerType.worker_classes.map(&:service_base_name)
  end

  def systemd_service_name(unit)
    File.basename(unit[:name], ".*")
  end

  def systemd_service_base_name(unit)
    systemd_service_name(unit).split("@").first
  end

  def failed_miq_services
    miq_services.select { |service| service[:active_state] == "failed" }
  end

  def failed_miq_service_names
    failed_miq_services.pluck(:name)
  end

  def systemd_services
    systemd_units.select { |unit| File.extname(unit[:name]) == ".service" }
  end

  def systemd_units
    systemd_manager.units
  end
end
