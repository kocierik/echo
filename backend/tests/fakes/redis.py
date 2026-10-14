"""An in-memory stand-in for the few Redis calls the API makes (auth limit, queues, markers)."""


class InMemoryRedis:
    def __init__(self):
        self.values: dict[str, object] = {}
        self.ttls: dict[str, int] = {}
        self.lists: dict[str, list] = {}

    async def get(self, key):
        value = self.values.get(key)
        if value is None or isinstance(value, bytes):
            return value
        return str(value).encode()

    async def set(self, key, value, nx=False, ex=None):
        if nx and key in self.values:
            return None
        self.values[key] = value
        if ex is not None:
            self.ttls[key] = ex
        return True

    async def delete(self, *keys):
        removed = 0
        for key in keys:
            removed += self.values.pop(key, None) is not None
            self.ttls.pop(key, None)
        return removed

    async def incr(self, key):
        self.values[key] = int(self.values.get(key, 0)) + 1
        return self.values[key]

    async def expire(self, key, seconds):
        self.ttls[key] = seconds

    async def ttl(self, key):
        return self.ttls.get(key, -1)

    async def lpush(self, key, *values):
        self.lists.setdefault(key, [])[:0] = reversed(values)
        return len(self.lists[key])

    async def llen(self, key):
        return len(self.lists.get(key, []))

    async def aclose(self):
        pass
