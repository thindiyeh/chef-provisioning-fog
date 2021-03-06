# fog:OpenStack:https://identifyhost:portNumber/v2.0
class Chef
module Provisioning
module FogDriver
  module Providers
    class OpenStack < FogDriver::Driver

      Driver.register_provider_class('OpenStack', FogDriver::Providers::OpenStack)

      def creator
        compute_options[:openstack_username]
      end

      def create_winrm_transport(machine_spec, machine_options, server)
        remote_host = if machine_spec.reference['use_private_ip_for_ssh']
                        server.private_ip_address
                      elsif !server.public_ip_address
                        Chef::Log.warn("Server #{machine_spec.name} has no public ip address.  Using private ip '#{server.private_ip_address}'.  Set driver option 'use_private_ip_for_ssh' => true if this will always be the case ...")
                        server.private_ip_address
                      elsif server.public_ip_address
                        server.public_ip_address
                      else
                        fail "Server #{server.id} has no private or public IP address!"
                      end
        Chef::Log::info("Connecting to server #{remote_host}")

        port = machine_spec.reference['winrm_port'] || 5986
        endpoint = "https://#{remote_host}:#{port}/wsman"
        type = :ssl
        pem_bytes = private_key_for(machine_spec, machine_options, server)
        encrypted_admin_password = wait_for_admin_password(machine_spec)
        decoded = Base64.decode64(encrypted_admin_password)
        private_key = OpenSSL::PKey::RSA.new(pem_bytes)
        decrypted_password = private_key.private_decrypt decoded


        # Use basic HTTPS auth - this is required for the WinRM setup we
        # are using
        # TODO: Improve that.
        options = {
            :user => machine_spec.reference['winrm.username'] || 'Admin',
            :pass => decrypted_password,
            :disable_sspi => true,
            :basic_auth_only => true,
            :no_ssl_peer_verification=>true,
            :ca_trust_path=>nil
        }

        Chef::Provisioning::Transport::WinRM.new(endpoint, type, options, {})
      end

      # Wait for the Windows Admin password to become available
      # @param [Hash] machine_spec Machine spec data
      # @return [String] encrypted admin password
      def wait_for_admin_password(machine_spec)
        time_elapsed = 0
        sleep_time = 10
        max_wait_time = 900 # 15 minutes
        encrypted_admin_password = nil
        instance_id = machine_spec.location['server_id']


        Chef::Log.info "waiting for #{machine_spec.name}'s admin password to be available..."
        while time_elapsed < max_wait_time && encrypted_admin_password.nil? || encrypted_admin_password.empty?
          response = compute.get_server_password(instance_id)
          encrypted_admin_password = response.body['password']
          if encrypted_admin_password.nil? || encrypted_admin_password.empty?
            Chef::Log.info "#{time_elapsed}/#{max_wait_time}s elapsed -- sleeping #{sleep_time} seconds for #{machine_spec.name}'s admin password."
            sleep(sleep_time)
            time_elapsed += sleep_time
          end
        end

        Chef::Log.info "#{machine_spec.name}'s admin password is available!'"

        encrypted_admin_password
      end

      def self.compute_options_for(provider, id, config)
        new_compute_options = {}
        new_compute_options[:provider] = provider
        new_config = { :driver_options => { :compute_options => new_compute_options }}
        new_defaults = {
          :driver_options => { :compute_options => {} },
          :machine_options => { :bootstrap_options => {} }
        }
        result = Cheffish::MergedConfig.new(new_config, config, new_defaults)

        new_compute_options[:openstack_auth_url] = id if (id && id != '')
        credential = Fog.credentials

        new_compute_options[:openstack_username] ||= credential[:openstack_username]
        new_compute_options[:openstack_api_key] ||= credential[:openstack_api_key]
        new_compute_options[:openstack_auth_url] ||= credential[:openstack_auth_url]
        new_compute_options[:openstack_tenant] ||= credential[:openstack_tenant]

        id = result[:driver_options][:compute_options][:openstack_auth_url]

        [result, id]
      end

      # Image methods
      def allocate_image(action_handler, image_spec, image_options, machine_spec, machine_options)
        image = image_for(image_spec)
        if image
          raise "The image already exists, why are you asking me to create it?  I can't do that, Dave."
        end
        action_handler.perform_action "Create image #{image_spec.name} from machine #{machine_spec.name} with options #{image_options.inspect}" do
          response = compute.create_image(
            machine_spec.reference['server_id'], image_spec.name,
            {
              description: "The Image named '#{image_spec.name}"
            })

          image_spec.reference = {
            driver_url: driver_url,
            driver_version: FogDriver::VERSION,
            image_id: response.body['image']['id'],
            creator: creator,
            allocated_it: Time.new.to_i
          }
        end
      end

      def ready_image(action_handler, image_spec, image_options)
        actual_image = image_for(image_spec)
        if actual_image.nil?
          raise 'Cannot ready an image that does not exist'
        else
          if actual_image.status != 'ACTIVE'
            action_handler.report_progress 'Waiting for image to be active ...'
            wait_until_ready_image(action_handler, image_spec, actual_image)
          else
            action_handler.report_progress "Image #{image_spec.name} is active!"
          end
        end
      end

      def destroy_image(action_handler, image_spec, image_options)
        image = image_for(image_spec)
        unless image.status == "DELETED"
          image.destroy
        end
      end

      def wait_until_ready_image(action_handler, image_spec, image=nil)
        wait_until_image(action_handler, image_spec, image) { image.status == 'ACTIVE' }
      end

      def wait_until_image(action_handler, image_spec, image=nil, &block)
        image ||= image_for(image_spec)
        time_elapsed = 0
        sleep_time = 10
        max_wait_time = 300
        if !yield(image)
          action_handler.report_progress "waiting for image #{image_spec.name} (#{image.id} on #{driver_url}) to be active ..."
          while time_elapsed < max_wait_time && !yield(image)
           action_handler.report_progress "been waiting #{time_elapsed}/#{max_wait_time} -- sleeping #{sleep_time} seconds for image #{image_spec.name} (#{image.id} on #{driver_url}) to be ACTIVE instead of #{image.status}..."
           sleep(sleep_time)
           image.reload
           time_elapsed += sleep_time
          end
          unless yield(image)
            raise "Image #{image.id} did not become ready within #{max_wait_time} seconds"
          end
          action_handler.report_progress "Image #{image_spec.name} is now ready"
        end
      end

      def image_for(image_spec)
        if image_spec.reference
          compute.images.get(image_spec.reference[:image_id]) || compute.images.get(image_spec.reference['image_id'])
        else
          nil
        end
      end

    end
  end
end
end
end
