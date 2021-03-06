require_relative "infrastructure"
require_relative "powerable"
require_relative "vm"

module VCloudSdk
  class VApp
    include Infrastructure
    include Powerable

    def initialize(session, link)
      @session = session
      @link = link
    end

    def name
      entity_xml.name
    end

    def delete
      vapp = entity_xml
      vapp_name = name

      if is_status?(vapp, :POWERED_ON)
        fail CloudError,
             "vApp #{vapp_name} is powered on, power-off before deleting."
      end

      wait_for_running_tasks(vapp, "VApp #{vapp_name}")

      Config.logger.info "Deleting vApp #{vapp_name}."
      monitor_task(connection.delete(vapp.remove_link),
                   @session.time_limit[:delete_vapp]) do |task|
        Config.logger.info "vApp #{vapp_name} deleted."
        return task
      end

      fail ApiRequestError,
           "Fail to delete vApp #{vapp_name}"
    end

    def recompose_from_vapp_template(catalog_name, template_name)
      recompose_vapp_link = get_recompose_vapp_link

      Config.logger.info "Recomposing from template '#{template_name}' in catalog '#{catalog_name}'."
      catalog = find_catalog_by_name catalog_name

      template = catalog.find_vapp_template_by_name template_name

      task = connection.post recompose_vapp_link.href,
                             recompose_from_vapp_template_param(template)

      monitor_task task, @session.time_limit[:recompose_vapp]
      Config.logger.info "vApp #{name} is recomposed."
      self
    end

    def remove_vm_by_name (vm_name)
      target_vm = find_vm_by_name vm_name
      unless target_vm
        fail ObjectNotFoundError,
             "VM #{vm_name} does not exist."
      end

      recompose_vapp_link = get_recompose_vapp_link

      task = connection.post recompose_vapp_link.href,
                             remove_vm_param(target_vm)

      monitor_task task, @session.time_limit[:recompose_vapp]
      Config.logger.info "VM #{vm_name} is removed."
      self
    end

    def vms
      entity_xml.vms.map do |vm|
        VCloudSdk::VM.new(@session, vm.href)
      end
    end

    def list_vms
      entity_xml.vms.map do |vm|
        vm.name
      end
    end

    def find_vm_by_name(name)
      entity_xml.vms.each do |vm|
        if vm.name == name
          return VCloudSdk::VM.new(@session, vm.href)
        end
      end

      fail ObjectNotFoundError, "VM '#{name}' is not found"
    end

    private

    def recompose_from_vapp_template_param(template)
      Xml::WrapperFactory.create_instance("RecomposeVAppParams").tap do |params|
        params.name = name
        params.all_eulas_accepted = true
        params.add_source_item template.href
      end
    end

    def get_recompose_vapp_link
      recompose_vapp_link = connection
                              .get(@link)
                              .recompose_vapp_link

      if recompose_vapp_link.nil?
        # We are able to recompose vapp when it is suspended or powered off
        # If vapp is powered on, throw exception
        fail CloudError,
             "VApp is in status of '#{status}' and can not be recomposed"
      end

      recompose_vapp_link
    end

    def remove_vm_param(vm)
      Xml::WrapperFactory.create_instance("RecomposeVAppParams").tap do |params|
        params.name = name
        params.all_eulas_accepted = true
        params.add_delete_item vm.href
      end
    end
  end
end
