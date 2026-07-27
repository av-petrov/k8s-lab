/*
Copyright 2021 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package kind

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"sigs.k8s.io/e2e-framework/pkg/env"
	"sigs.k8s.io/e2e-framework/pkg/envconf"
	"sigs.k8s.io/e2e-framework/pkg/envfuncs"
	"sigs.k8s.io/e2e-framework/support/kind"
)

var testenv env.Environment

func init() {
	fmt.Println("init from main_test.go")
}

func TestMain(m *testing.M) {
	testenv, _ = env.NewFromFlags()
	kindClusterName := envconf.RandomName("kind-e2e", 20)
	namespace := envconf.RandomName("kind-ns", 16)

	testenv.Setup(
		envfuncs.CreateClusterWithConfig(
			kind.NewProvider(),
			kindClusterName,
			"dev02.yaml",
			kind.WithImage(
				"kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5",
			),
		),
		envfuncs.CreateNamespace(namespace),
	)

	logsDir := filepath.Join("logs", kindClusterName)

	testenv.Finish(
		envfuncs.DeleteNamespace(namespace),
		envfuncs.ExportClusterLogs(kindClusterName, logsDir),
		envfuncs.DestroyCluster(kindClusterName),
	)
	os.Exit(testenv.Run(m))
}
