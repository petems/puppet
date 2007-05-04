require 'puppet'
require 'puppet/daemon'
require 'webrick'
require 'webrick/https'

require 'puppet/sslcertificates/support'
require 'puppet/network/xmlrpc/webrick_servlet'
require 'puppet/network/server'
require 'puppet/network/client'

module Puppet
    class ServerError < RuntimeError; end
    module Network
        # The old-school, pure ruby webrick server, which is the default serving
        # mechanism.
        class Server::WEBrick < WEBrick::HTTPServer
            include Puppet::Daemon
            include Puppet::SSLCertificates::Support

            # Read the CA cert and CRL and populate an OpenSSL::X509::Store
            # with them, with flags appropriate for checking client 
            # certificates for revocation
            def x509store
                if Puppet[:cacrl] == 'none'
                    # No CRL, no store needed
                    return nil
                end
                unless File.exist?(Puppet[:cacrl])
                    raise Puppet::Error, "Could not find CRL"
                end
                crl = OpenSSL::X509::CRL.new(File.read(Puppet[:cacrl]))
                store = OpenSSL::X509::Store.new
                store.purpose = OpenSSL::X509::PURPOSE_ANY
                store.flags = OpenSSL::X509::V_FLAG_CRL_CHECK_ALL|OpenSSL::X509::V_FLAG_CRL_CHECK
                unless self.ca_cert
                    raise Puppet::Error, "No CA certificate"
                end

                store.add_file(Puppet[:localcacert])
                store.add_crl(crl)
                return store
            end

            # Set up the http log.
            def httplog
                args = []

                # yuck; separate http logs
                file = nil
                Puppet.config.use(:main, :ssl, Puppet[:name])
                if Puppet[:name] == "puppetmasterd"
                    file = Puppet[:masterhttplog]
                else
                    file = Puppet[:httplog]
                end

                args << file
                if Puppet[:debug]
                    args << WEBrick::Log::DEBUG
                end

                log = WEBrick::Log.new(*args)


                return log
            end

            # Create our server, yo.
            def initialize(hash = {})
                Puppet.info "Starting server for Puppet version %s" % Puppet.version

                if handlers = hash[:Handlers]
                    handler_instances = setup_handlers(handlers)
                else
                    raise ServerError, "A server must have handlers"
                end

                unless self.read_cert
                    if ca = handler_instances.find { |handler| handler.is_a?(Puppet::Network::Handler.ca) }
                        request_cert(ca)
                    else
                        raise Puppet::Error, "No certificate and no CA; cannot get cert"
                    end
                end

                setup_webrick(hash)

                super(hash)

                Puppet.info "Listening on port %s" % hash[:Port]

                # this creates a new servlet for every connection,
                # but all servlets have the same list of handlers
                # thus, the servlets can have their own state -- passing
                # around the requests and such -- but the handlers
                # have a global state

                # mount has to be called after the server is initialized
                servlet = Puppet::Network::XMLRPC::WEBrickServlet.new(
                    handler_instances)
                self.mount("/RPC2", servlet)
            end

            # Create a ca client to set up our cert for us.
            def request_cert(ca)
                client = Puppet::Network::Client.ca.new(:CA => ca)
                unless client.request_cert
                    raise Puppet::Error, "Could get certificate"
                end
            end

            # Create all of our handler instances.
            def setup_handlers(handlers)
                unless handlers.is_a?(Hash)
                    raise ServerError, "Handlers must have arguments"
                end

                handlers.collect { |handler, args|
                    hclass = nil
                    unless hclass = Handler.handler(handler)
                        raise ServerError, "Invalid handler %s" % handler
                    end
                    hclass.new(args)
                }
            end

            # Handle all of the many webrick arguments.
            def setup_webrick(hash)
                hash[:Port] ||= Puppet[:masterport]
                hash[:Logger] ||= self.httplog
                hash[:AccessLog] ||= [
                    [ self.httplog, WEBrick::AccessLog::COMMON_LOG_FORMAT ],
                    [ self.httplog, WEBrick::AccessLog::REFERER_LOG_FORMAT ]
                ]

                hash[:SSLCertificateStore] = x509store
                hash[:SSLCertificate] = self.cert
                hash[:SSLPrivateKey] = self.key
                hash[:SSLStartImmediately] = true
                hash[:SSLEnable] = true
                hash[:SSLCACertificateFile] = Puppet[:localcacert]
                hash[:SSLVerifyClient] = OpenSSL::SSL::VERIFY_PEER
                hash[:SSLCertName] = nil

                if addr = Puppet[:bindaddress] and addr != ""
                    hash[:BindAddress] = addr
                end
            end
        end
    end
end

# $Id$
