{
  services.mosquitto = {
    enable = true;
    listeners = [
      {
        address = "192.168.178.10";
        port = 1883;
        acl = [ "pattern readwrite #" ];
        omitPasswordAuth = true;
        settings.allow_anonymous = true;
      }
    ];
  };
}
