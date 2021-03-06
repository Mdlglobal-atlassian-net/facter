require 'open-uri'
require 'open3'
require 'uri'

module Puppet
  module Acceptance
    module InstallUtils
      PLATFORM_PATTERNS = {
        :redhat        => /fedora|el|centos/,
        :debian        => /debian|ubuntu/,
        :debian_ruby18 => /debian|ubuntu-lucid|ubuntu-precise/,
        :solaris       => /solaris/,
        :windows       => /windows/,
      }.freeze

      # Installs packages on the hosts.
      #
      # @param hosts [Array<Host>] Array of hosts to install packages to.
      # @param package_hash [Hash{Symbol=>Array<String,Array<String,String>>}]
      #   Keys should be a symbol for a platform in PLATFORM_PATTERNS.  Values
      #   should be an array of package names to install, or of two element
      #   arrays where a[0] is the command we expect to find on the platform
      #   and a[1] is the package name (when they are different).
      # @param options [Hash{Symbol=>Boolean}]
      # @option options [Boolean] :check_if_exists First check to see if
      #   command is present before installing package.  (Default false)
      # @return true
      def install_packages_on(hosts, package_hash, options = {})
        check_if_exists = options[:check_if_exists]
        hosts = [hosts] unless hosts.kind_of?(Array)
        hosts.each do |host|
          package_hash.each do |platform_key,package_list|
            if pattern = PLATFORM_PATTERNS[platform_key]
              if pattern.match(host['platform'])
                package_list.each do |cmd_pkg|
                  if cmd_pkg.kind_of?(Array)
                    command, package = cmd_pkg
                  else
                    command = package = cmd_pkg
                  end
                  if !check_if_exists || !host.check_for_package(command)
                    host.logger.notify("Installing #{package}")
                    additional_switches = '--allow-unauthenticated' if platform_key == :debian
                    host.install_package(package, additional_switches)
                  end
                end
              end
            else
              raise("Unknown platform '#{platform_key}' in package_hash")
            end
          end
        end
        return true
      end

      def fetch(base_url, file_name, dst_dir)
        FileUtils.makedirs(dst_dir)
        src = "#{base_url}/#{file_name}"
        dst = File.join(dst_dir, file_name)
        if File.exists?(dst)
          logger.notify "Already fetched #{dst}"
        else
          logger.notify "Fetching: #{src}"
          logger.notify "  and saving to #{dst}"
          open(src) do |remote|
            File.open(dst, "w") do |file|
              FileUtils.copy_stream(remote, file)
            end
          end
        end
        return dst
      end

      def fetch_remote_dir(url, dst_dir)
        logger.notify "fetch_remote_dir (url: #{url}, dst_dir #{dst_dir})"
        if url[-1, 1] !~ /\//
          url += '/'
        end
        url = URI.parse(url)
        chunks = url.path.split('/')
        dst = File.join(dst_dir, chunks.last)
        #determine directory structure to cut
        #only want to keep the last directory, thus cut total number of dirs - 2 (hostname + last dir name)
        cut = chunks.length - 2
        wget_command = "wget -nv -P #{dst_dir} --reject \"index.html*\",\"*.gif\" --cut-dirs=#{cut} -np -nH --no-check-certificate -r #{url}"

        logger.notify "Fetching remote directory: #{url}"
        logger.notify "  and saving to #{dst}"
        logger.notify "  using command: #{wget_command}"

        #in ruby 1.9+ we can upgrade this to popen3 to gain access to the subprocess pid
        result = `#{wget_command} 2>&1`
        result.each_line do |line|
          logger.debug(line)
        end
        if $?.to_i != 0
          raise "Failed to fetch_remote_dir '#{url}' (exit code #{$?}"
        end
        dst
      end

      def stop_firewall_on(host)
        case host['platform']
        when /debian/
          on host, 'iptables -F'
        when /fedora|el-7/
          on host, puppet('resource', 'service', 'firewalld', 'ensure=stopped')
        when /el|centos/
          on host, puppet('resource', 'service', 'iptables', 'ensure=stopped')
        when /ubuntu/
          on host, puppet('resource', 'service', 'ufw', 'ensure=stopped')
        else
          logger.notify("Not sure how to clear firewall on #{host['platform']}")
        end
      end

      def install_repos_on(host, sha, repo_configs_dir)
        platform = host['platform'].with_version_codename
        platform_configs_dir = File.join(repo_configs_dir,platform)

        case platform
          when /^(fedora|el|centos)-(\d+)-(.+)$/
            variant = (($1 == 'centos') ? 'el' : $1)
            fedora_prefix = ((variant == 'fedora') ? 'f' : '')
            version = $2
            arch = $3

            rpm = fetch(
              "http://yum.puppetlabs.com",
              "puppetlabs-release-%s-%s.noarch.rpm" % [variant, version],
              platform_configs_dir
            )

            pattern = "pl-facter-%s-%s-%s%s-%s.repo"
            repo_filename = pattern % [
              sha,
              variant,
              fedora_prefix,
              version,
              arch
            ]
            repo = fetch(
              "http://builds.puppetlabs.lan/facter/%s/repo_configs/rpm/" % sha,
              repo_filename,
              platform_configs_dir
            )

            link = "http://builds.puppetlabs.lan/facter/%s/repos/%s/%s%s/products/%s/" % [sha, variant, fedora_prefix, version, arch]
            if not link_exists?(link)
              link = "http://builds.puppetlabs.lan/facter/%s/repos/%s/%s%s/devel/%s/" % [sha, variant, fedora_prefix, version, arch]
            end
            if not link_exists?(link)
              raise "Unable to reach a repo directory at #{link}"
            end
            repo_dir = fetch_remote_dir(link, platform_configs_dir)

            on host, "rm -rf /root/*.repo; rm -rf /root/*.rpm; rm -rf /root/#{arch}"

            scp_to host, rpm, '/root'
            scp_to host, repo, '/root'
            scp_to host, repo_dir, '/root'

            on host, "mv /root/*.repo /etc/yum.repos.d"
            on host, "find /etc/yum.repos.d/ -name \"*.repo\" -exec sed -i \"s/baseurl\\s*=\\s*http:\\/\\/builds.puppetlabs.lan.*$/baseurl=file:\\/\\/\\/root\\/#{arch}/\" {} \\;"
            on host, "rpm -Uvh --force /root/*.rpm"

          when /^(debian|ubuntu)-([^-]+)-(.+)$/
            variant = $1
            version = $2
            arch = $3

            deb = fetch(
              "http://apt.puppetlabs.com/",
              "puppetlabs-release-%s.deb" % version,
              platform_configs_dir
            )

            list = fetch(
              "http://builds.puppetlabs.lan/facter/%s/repo_configs/deb/" % sha,
              "pl-facter-%s-%s.list" % [sha, version],
              platform_configs_dir
            )

            repo_dir = fetch_remote_dir("http://builds.puppetlabs.lan/facter/%s/repos/apt/%s" % [sha, version], platform_configs_dir)

            on host, "rm -rf /root/*.list; rm -rf /root/*.deb; rm -rf /root/#{version}"

            scp_to host, deb, '/root'
            scp_to host, list, '/root'
            scp_to host, repo_dir, '/root'

            on host, "mv /root/*.list /etc/apt/sources.list.d"
            on host, "find /etc/apt/sources.list.d/ -name \"*.list\" -exec sed -i \"s/deb\\s\\+http:\\/\\/builds.puppetlabs.lan.*$/deb file:\\/\\/\\/root\\/#{version} #{version} main/\" {} \\;"
            on host, "dpkg -i --force-all /root/*.deb"
            on host, "apt-get update"
          else
            host.logger.notify("No repository installation step for #{platform} yet...")
        end
      end
    end
  end
end
