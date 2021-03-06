require "spec_helper"
require_relative "mocks/client_response"
require_relative "mocks/response_mapping"
require_relative "mocks/rest_client"
require "nokogiri/diff"

describe VCloudSdk::VM do

  let(:logger) { VCloudSdk::Test.logger }
  let(:url) { VCloudSdk::Test::Response::URL }
  let(:disk_name) { VCloudSdk::Test::Response::INDY_DISK_NAME }
  let(:disk) do
    vdc_response = VCloudSdk::Xml::WrapperFactory.wrap_document(
      VCloudSdk::Test::Response::VDC_RESPONSE)

    disk_link = vdc_response
                  .disks(disk_name)
    VCloudSdk::Disk.new(VCloudSdk::Test.mock_session(logger, url),
                        disk_link)
  end

  let(:vm_name) { VCloudSdk::Test::Response::VM_NAME }
  let(:catalog_name) { VCloudSdk::Test::Response::CATALOG_NAME }
  let(:media_name) { VCloudSdk::Test::Response::EXISTING_MEDIA_NAME }

  subject do
    described_class.new(VCloudSdk::Test.mock_session(logger, url),
                        VCloudSdk::Test::Response::INSTANTIATED_VM_LINK)
  end

  describe "#href" do
    it "returns the link of VM" do
      subject.href.should eql VCloudSdk::Test::Response::INSTANTIATED_VM_LINK
    end
  end

  describe "#name" do
    it "returns the name of VM" do
      subject.name.should eql vm_name
    end
  end

  describe "#independent_disks" do
    context "vm has attached disk" do
      it "returns a collection of disks" do
        VCloudSdk::Test::ResponseMapping.set_option vm_disk_attached: true
        disks = subject.independent_disks
        disks.should have(1).item
        disk = disks[0]
        disk.should be_an_instance_of VCloudSdk::Disk
        disk.name.should eql disk_name
      end
    end

    context "vm has no attached disk" do
      before do
        VCloudSdk::Test::ResponseMapping.delete_option :vm_disk_attached
      end

      its(:independent_disks) { should eql [] }
    end
  end

  describe "#list_disks" do
    context "vm has attached disk" do
      before do
        VCloudSdk::Test::ResponseMapping.set_option vm_disk_attached: true
      end

      its(:list_disks) { should eql ["Hard disk 1", "Hard disk 2 (#{disk_name})"] }
    end

    context "vm has no attached disk" do
      before do
        VCloudSdk::Test::ResponseMapping.delete_option :vm_disk_attached
      end

      its(:list_disks) { should eql ["Hard disk 1"] }
    end
  end

  describe "#attach_disk" do
    context "the disk is already attached to VM" do
      it "raises an error" do
        VCloudSdk::Test::ResponseMapping
          .set_option disk_state: :attached
        expect do
          subject.attach_disk(disk)
        end.to raise_exception VCloudSdk::CloudError,
                               "Disk '#{disk.name}' of link #{disk.href} is attached to VM '#{disk.vm.name}'"
      end
    end

    context "the disk is not attached to any VM" do
      before do
        VCloudSdk::Test::ResponseMapping
          .set_option disk_state: :not_attached
      end

      it "attaches the disk successfully" do
        attach_task = subject.attach_disk(disk)
        subject
          .send(:task_is_success, attach_task)
          .should be_true
      end

      context "error occurs when attaching disk" do

        it "raises the exception" do
          subject
            .send(:connection)
            .should_receive(:post)
            .once
            .with(VCloudSdk::Test::Response::INSTANTIATED_VM_ATTACH_DISK_LINK,
                  anything,
                  VCloudSdk::Xml::MEDIA_TYPE[:DISK_ATTACH_DETACH_PARAMS])
            .and_raise RestClient::BadRequest

          expect do
            subject.attach_disk(disk)
          end.to raise_exception RestClient::BadRequest
        end
      end
    end
  end

  describe "#detach_disk" do
    context "vApp is suspended" do
      it "raises VmSuspendedError" do
        VCloudSdk::Test::ResponseMapping
          .set_option vapp_power_state: :suspended

        expect do
          subject.detach_disk(disk)
        end.to raise_exception VCloudSdk::VmSuspendedError,
                               "vApp #{VCloudSdk::Test::Response::VAPP_NAME}" +
                               " suspended, discard state before detaching disk."
      end
    end

    context "vApp is powered on" do
      before do
        VCloudSdk::Test::ResponseMapping
          .set_option vapp_power_state: :on
      end

      context "the disk is not attached to any VM" do
        it "raises an error" do
          VCloudSdk::Test::ResponseMapping
            .set_option disk_state: :not_attached

          expect do
            subject.detach_disk(disk)
          end.to raise_exception VCloudSdk::CloudError,
                                 "No vm is attached to disk '#{disk.name}'"
        end
      end

      context "the disk is attached to other VM" do
        it "raises an error" do
          VCloudSdk::Test::ResponseMapping
            .set_option disk_state: :attached

          other_vm = double("other VM")
          other_vm
            .stub(:name) { "other VM" }
          other_vm
            .stub(:href) { "other vm link" }

          disk
            .should_receive(:vm)
            .and_return other_vm

          expect do
            subject.detach_disk(disk)
          end.to raise_exception VCloudSdk::CloudError,
                                 "Disk '#{disk.name}' is attached to other VM - name: 'other VM', link 'other vm link'"
        end
      end

      context "the disk is attached to current VM" do
        before do
          VCloudSdk::Test::ResponseMapping
            .set_option disk_state: :attached
        end

        it "detaches the disk successfully" do
          detach_task = subject.detach_disk(disk)
          subject
            .send(:task_is_success, detach_task)
            .should be_true
        end

        context "error occurs when attaching disk" do
          it "raises the exception" do
            subject
              .send(:connection)
              .should_receive(:post)
              .once
              .with(VCloudSdk::Test::Response::INSTANTIATED_VM_DETACH_DISK_LINK,
                    anything,
                    VCloudSdk::Xml::MEDIA_TYPE[:DISK_ATTACH_DETACH_PARAMS])
              .and_raise RestClient::BadRequest

            expect do
              subject.detach_disk(disk)
            end.to raise_exception RestClient::BadRequest
          end
        end
      end
    end
  end

  describe "#status" do
    context "VM is powered on" do
      it "returns status POWERED_ON" do
        VCloudSdk::Xml::Vm
          .any_instance
          .stub(:[])
          .with(:status) { "4" }
        subject.status.should eql "POWERED_ON"
      end
    end

    context "VM is powered off" do
      it "returns the status POWERED_OFF" do
        VCloudSdk::Xml::Vm
          .any_instance
          .stub(:[])
          .with(:status) { "8" }
        subject.status.should eql "POWERED_OFF"
      end
    end

    context "VM is suspended" do
      it "returns the status SUSPENDED" do
        VCloudSdk::Xml::Vm
          .any_instance
          .stub(:[])
          .with(:status) { "3" }
        subject.status.should eql "SUSPENDED"
      end
    end
  end

  describe "#power_on" do
    context "VM is powered off" do
      before do
        VCloudSdk::Xml::Vm
          .any_instance
          .stub(:[])
          .with(:status) { "8" }
      end

      it "powers on target VM successfully" do
        power_on_task = subject.power_on
        subject.send(:task_is_success, power_on_task)
          .should be_true
      end

      context "request to power on VM times out" do
        it "fails to power on VM" do
          subject
            .should_receive(:task_is_success)
            .at_least(3)
            .and_return(false)

          expect { subject.power_on }
          .to raise_exception VCloudSdk::ApiTimeoutError,
                              "Task Starting Virtual Machine sc-1f9f883e-968c-4bad-88e3-e7cb36881788(b2ee6bb6-d70f-4c54-8789-c2fd123c6491)" +
                              " did not complete within limit of 3 seconds."
        end
      end
    end

    context "VM is powered on" do
      before do
        VCloudSdk::Xml::Vm
          .any_instance
          .stub(:[])
          .with(:status) { "4" }
      end

      it "does not try to power on VM again" do
        subject.send(:connection)
          .should_not_receive(:post)

        subject.power_on
      end
    end
  end

  describe "#power_off" do

    context "VM is powered on" do
      before do
        VCloudSdk::Xml::Vm
          .any_instance
          .stub(:[])
          .with(:status) { "4" }
      end

      it "powers off target VM successfully" do
        power_off_task = subject.power_off
        subject.send(:task_is_success, power_off_task)
          .should be_true
      end

      context "request to power off VM times out" do
        it "fails to power off VM" do
          subject
            .should_receive(:task_is_success)
            .at_least(3)
            .and_return(false)

          expect { subject.power_off }
          .to raise_exception VCloudSdk::ApiTimeoutError,
                              "Task Starting Virtual Machine sc-1f9f883e-968c-4bad-88e3-e7cb36881788(b2ee6bb6-d70f-4c54-8789-c2fd123c6491)" +
                              " did not complete within limit of 3 seconds."
        end
      end
    end

    context "VM is powered off" do
      before do
        VCloudSdk::Xml::Vm
          .any_instance
          .stub(:[])
          .with(:status) { "8" }
      end

      it "does not try to power off the VM again" do
        subject
          .send(:connection)
          .should_not_receive(:post)

        subject.power_off
      end
    end

    context "VM is suspended" do
      before do
        VCloudSdk::Xml::Vm
          .any_instance
          .stub(:[])
          .with(:status) { "3" }
      end

      it "raises an error" do
        subject
          .send(:connection)
          .should_not_receive(:post)

        expect { subject.power_off }
        .to raise_exception VCloudSdk::VmSuspendedError,
                            "VM #{vm_name} suspended, discard state before powering off."
      end
    end
  end

  describe "#insert_media" do
    context "catalog containing media file does not exist" do
      it "raises ObjectNotFoundError" do
        expect do
          subject.insert_media("dummy", "dummy")
        end.to raise_exception VCloudSdk::ObjectNotFoundError,
                               "Catalog 'dummy' is not found"
      end
    end

    context "catalog containing media file exists" do
      before do
        VCloudSdk::Test::ResponseMapping
          .set_option catalog_state: :added
      end

      context "media file matching the name does not exist" do
        it "raises ObjectNotFoundError" do
          expect do
            subject.insert_media(catalog_name, "dummy")
          end.to raise_exception VCloudSdk::ObjectNotFoundError,
                                 "Catalog Item 'dummy' is not found"
        end
      end

      context "media file matching the name exists" do
        before do
          VCloudSdk::Test::ResponseMapping
            .set_option existing_media_state: :done
        end

        context "media file has a running task" do
          it "inserts media file successfully" do
            VCloudSdk::Test::ResponseMapping
              .set_option existing_media_state: :busy
            task = subject.insert_media(catalog_name,
                                        media_name)
            subject
              .send(:task_is_success, task)
              .should be_true
          end
        end

        context "media file has no running task" do
          it "inserts media file successfully" do
            task = subject.insert_media(catalog_name,
                                        media_name)

            subject
              .send(:task_is_success, task)
              .should be_true
          end
        end

        context "error occurs when inserting media" do
          it "raises the exception" do
            subject
              .send(:connection)
              .should_receive(:post)
              .once
              .with(VCloudSdk::Test::Response::INSTANTIATED_VM_INSERT_MEDIA_LINK,
                    anything,
                    VCloudSdk::Xml::MEDIA_TYPE[:MEDIA_INSERT_EJECT_PARAMS])
              .and_raise RestClient::BadRequest

            expect do
              subject.insert_media(catalog_name,
                                   media_name)
            end.to raise_exception RestClient::BadRequest
          end
        end
      end
    end
  end
end
