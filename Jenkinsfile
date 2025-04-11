pipeline {
    agent {
        label "build-slave || single-executor-nodes"
    }
    stages {
        stage ("Run CI/CD") {
            steps {
                script {
                    if (env.CHANGE_BRANCH) { // pull request
                        build job: 'runfile-installer/dev-jenkins', propagate: true, parameters: [string(name: 'GITHUB_BRANCH', value: "${env.CHANGE_BRANCH}")]
                    } else {
                        build job: 'runfile-installer/dev-jenkins', propagate: true, parameters: [string(name: 'GITHUB_BRANCH', value: "${env.BRANCH_NAME}")]
                    }
                }
            }
        }
    }
}