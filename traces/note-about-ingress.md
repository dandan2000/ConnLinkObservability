This way we can add x-request-id to IngressController

  httpHeaders:
    uniqueId:
      format: '%{+X}o %ci:%cp_%fi:%fp_%Ts_%rt:%pid'
      name: X-Request-ID
