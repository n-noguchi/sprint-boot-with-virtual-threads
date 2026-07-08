package com.example.bench;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestClient;

@RestController
public class ApiController {

    private final RestClient restClient;
    private final long api2DelayMs;

    public ApiController(
            @Value("${api2.url}") String api2Url,
            @Value("${api2.delay-ms:200}") long api2DelayMs) {
        this.restClient = RestClient.builder().baseUrl(api2Url).build();
        this.api2DelayMs = api2DelayMs;
    }

    @GetMapping("/api1")
    public String api1() {
        return restClient.get().uri("/api2").retrieve().body(String.class);
    }

    @GetMapping("/api2")
    public String api2() throws InterruptedException {
        Thread.sleep(api2DelayMs);
        return "ok";
    }

    @GetMapping("/thread")
    public String thread() {
        Thread t = Thread.currentThread();
        return "name=" + t.getName() + " isVirtual=" + t.isVirtual();
    }
}
