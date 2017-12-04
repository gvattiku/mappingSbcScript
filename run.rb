#!/usr/bin/env ruby

require 'socket'
require 'ipaddr'
require 'nmap'
require 'nmap/xml'
require 'rubyserial'


# All possible filenames the serial device can have
serialdevices = ['/dev/ttyACM0', '/dev/ttyACM1', '/dev/ttyACM2',
                 '/dev/ttyUSB0', '/dev/ttyUSB1', '/dev/ttyUSB2']
serialport = nil


# Try each of the serial devices until the Arduino is found
serialdevices.each do |dev|
  begin
    puts "Trying Serial Device #{dev}"
    serialport = Serial.new(dev)
    break if serialport
  rescue RubySerial::Exception => ex
    STDERR.puts "An exception occured trying to open #{dev}. Trying the next one"
  end
end

if serialport
  puts "Serial Device Found"
else
  puts "Serial Device Not Connected/Found"
end


# Get the computer's IP address
local_addr = Socket.ip_address_list.find { |a| a.ipv4? && !a.ipv4_loopback? }

# Get the computer's subnet address
subnet_addr = IPAddr.new(local_addr.ip_address).mask(24)

# Look up the IP address of the server
server_ip = nil

# Perform an `nmap` scan to get the IP address of the server
# The server has a UDP Server listening on port 1234 of the
# same subnet
Nmap::Program.scan do |nmap|
  nmap.udp_scan = true
  nmap.xml = 'scan.xml'
  nmap.ports = 1234

  # Routers usually have an address with the last octet being 1 or 100
  nmap.targets = subnet_addr.to_s.gsub(/\.0$/, '.2-255')
end

Nmap::XML.new('scan.xml') do |xml|
  xml.each_host do |host|
    if host.status.state == :up
      server_ip = host.to_s
      break
    end
  end
end

# Set up a UDP Socket to connect to the UDP Server
client = UDPSocket.new
client.connect(server_ip, 1234)
puts "UDPServer found: #{server_ip}"

# Initial Mouse Position
# These are thread unsafe globals but they are not mutated in
# more than one thread (the mouse position maintainer thread)
$x = 0
$y = 0

# Set property values for all available mice
mice = {
  dell: { file: '/dev/input/by-id/usb-PixArt_USB_Optical_Mouse-mouse', dpi: 1000.0 },
  zebronics: { file: '/dev/input/by-id/usb-15d9_USB_OPTICAL_MOUSE-mouse', dpi: 800.0 }
}

# Choose which mouse is to be read
mouse_connected = mice[:zebronics]

# Set current mouse properties
mouse_file = mouse_connected[:file]
mouse_dpi = mouse_connected[:dpi]

# A list of all threads to be run
threads = []

# Thread that tracks the mouse movements
threads << Thread.new do

  # Read mouse device file
  File.open(mouse_file) do |f|
    loop do
      _button, dx, dy =  f.read(3).unpack('Ccc')

      $x += dx
      $y += dy

      # Send to server
      if server_ip

        # Get position in cms
        position_x = $x * 2.5 / mouse_dpi
        position_y = $y * 2.5 / mouse_dpi

        # If the first 3 values are 0, just position is being sent
        payload = "0,0,0,%s,%s" % [position_x, position_y]
        client.send(payload, 0)
        puts payload

      end
    end
  end
end


# Thread to read serial data from the Arduino and
# send it to the server
threads << Thread.new do
  if serialport && server_ip

    loop do
      cms, angle_h, angle_v = serialport
                                .gets
                                .chomp
                                .split(',')

      next if !cms || !angle_h || !angle_v

      # Get position in cms
      position_x = $x * 2.5 / mouse_dpi
      position_y = $y * 2.5 / mouse_dpi

      payload = "%s,%s,%s,%s,%s" % [cms, angle_h, angle_v, position_x, position_y]
      client.send(payload, 0)
      puts payload
    end

  end
end

# Start the threads
threads.map(&:join)
