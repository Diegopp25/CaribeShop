from locust import HttpUser, between, task


class CaribeShopUser(HttpUser):
    wait_time = between(0.5, 1)

    @task
    def load_homepage(self):
        self.client.get("/", name="GET /")
