"""An in-memory stand-in for the few Redis calls the auth failure limit makes."""


class InMemoryRedis:
    def __init__(self):
        self.values: dict[str, int] = {}
        self.ttls: dict[str, int] = {}

    async def get(self, key):
        value = self.values.get(key)
        return None if value is None else str(value).encode()

    async def incr(self, key):
        self.values[key] = self.values.get(key, 0) + 1
        return self.values[key]

    async def expire(self, key, seconds):
        self.ttls[key] = seconds

    async def ttl(self, key):
        return self.ttls.get(key, -1)

    async def aclose(self):
        pass
