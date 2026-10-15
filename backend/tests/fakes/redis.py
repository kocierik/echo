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

    async def rpush(self, key, *values):
        self.lists.setdefault(key, []).extend(values)
        return len(self.lists[key])

    async def lpop(self, key):
        items = self.lists.get(key)
        return items.pop(0) if items else None

    async def blpop(self, keys, timeout=0):
        """Never blocks: a test that waits on an empty list gets the timeout at once."""
        for key in keys:
            if self.lists.get(key):
                return key, self.lists[key].pop(0)
        return None

    async def hset(self, key, field, value):
        self.values.setdefault(key, {})[field] = value
        return 1

    async def hdel(self, key, *fields):
        found = self.values.get(key, {})
        return sum(found.pop(field, None) is not None for field in fields)

    async def hgetall(self, key):
        return {
            k.encode(): v.encode() if isinstance(v, str) else v
            for k, v in dict(self.values.get(key, {})).items()
        }

    async def llen(self, key):
        return len(self.lists.get(key, []))

    async def aclose(self):
        pass
